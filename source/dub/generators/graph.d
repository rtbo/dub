/**
	Support for graph based builds.

	That means fine grained builds where only needed modules are rebuilt and
	builds are spread over all cores.
*/
module dub.generators.graph;

version (DubUseGraphBuild):

import dub.compilers.buildsettings;
import dub.compilers.compiler;
import dub.generators.generator;
import dub.internal.vibecompat.core.log;
import dub.project;

import std.datetime.systime : SysTime;

class BuildGraphGenerator : ProjectGenerator
{
	// the whole graph nodes and edges
	private Node[string] m_nodes;
	private Edge[] m_edges;

	// linked list of edges ready for process
	private Edge m_readyFirst;
	private Edge m_readyLast;

	// who many in total do we have to build
	private int m_numToBuild;

	this (Project project) {
		super(project);
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		import std.exception : enforce;

		// Can a generator be used multiple times?
		// We clear state in case of.
		m_nodes = null;
		m_edges = null;
		m_readyFirst = null;
		m_readyLast = null;
		m_numToBuild = 0;

		enforce(!settings.rdmd, "RDMD not supported for graph based builds");

		// step 1: recursive descent to build the dependency graph

		string[string] targetPaths;
		Node[string] targetNodes;

		Node buildTargetGraphRec(in string target)
		{
			auto pn = target in targetNodes;
			if (pn) return *pn;

			const ti = targets[target];

			Node[] depNodes;
			foreach (dep; ti.dependencies)
				// TODO: check optimization: building static libs do not need
				// dependencies to be linked. (but might need post build?)
				// current code is conservative: we always wait that dependencies are
				// linked to start generation the link process
				depNodes ~= buildTargetGraphRec(dep);

			auto bs = ti.buildSettings.dup;
			foreach (ldep; ti.linkDependencies) {
				if (bs.targetType != TargetType.staticLibrary && !(bs.options & BuildOption.syntaxOnly)) {
					bs.addSourceFiles(targetPaths[ldep]);
				}
			}

			string binPath;
			auto node = buildTargetGraph(ti, settings, bs, depNodes, binPath);
			targetPaths[target] = binPath;
			targetNodes[target] = node;
			return node;
		}

		auto rootNode = buildTargetGraphRec(m_project.rootPackage.name);

		// step 2: mark nodes that need to be rebuilt
		if (rootNode.inEdge && markNode(rootNode)) {
			import std.parallelism : totalCPUs;
			// step 3: actual build
			build(totalCPUs);
		}
		else {
			logInfo("%s: Nothing to do.", m_project.rootPackage.name);
		}
	}

	override void performPostGenerateActions(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		import std.path : buildPath;

		// run the generated executable
		auto buildsettings = targets[m_project.rootPackage.name].buildSettings.dup;
		if (settings.run && !(buildsettings.options & BuildOption.syntaxOnly)) {
			const exeFile = buildPath(
				m_project.rootPackage.path.toNativeString(),
				getTargetPath(buildsettings, settings)
			);
			runTarget(exeFile, buildsettings, settings.runArgs, settings);
		}
	}

	private void connect(Node[] inputs, Edge edge, Node[] outputs)
	{
		foreach (i; inputs) i.outEdges ~= edge;
		foreach (o; outputs) o.inEdge = edge;
		edge.inNodes ~= inputs;
		edge.outNodes ~= outputs;
	}

	private void connect(Node input, Edge edge, Node output)
	{
		input.outEdges ~= edge;
		output.inEdge = edge;
		edge.inNodes ~= input;
		edge.outNodes ~= output;
	}

	private void connect(Edge edge, Node output)
	{
		output.inEdge = edge;
		edge.outNodes ~= output;
	}

	private Node buildTargetGraph(in ref TargetInfo ti, ref GeneratorSettings gs,
				BuildSettings bs, Node[] linkDeps, out string binPath)
	{
		import std.format : format;

		// most can be in parallel, but there is a minimal sequence:
		// - prebuild commands (each in sequence)
		// - actual build and link
		// - postbuild commands (each in sequence)
		// this sequence is tracked with lastNode
		Node lastNode;
		Node linkNode;

		foreach (i, pbc; bs.preBuildCommands) {
			auto node = new PhonyNode(this, format("%s-prebuild-%s", ti.pack.name, i+1));
			auto edge = new ShellEdge(this, pbc);
			if (lastNode)
				connect(lastNode, edge, node);
			else
				connect(edge, node);
			lastNode = node;
		}

		if (!(bs.options & BuildOption.syntaxOnly)) {

			// TODO different build graphs following scenarios
			//  - single
			//  - local vs non-local packages
			//  - rdmd

			linkNode = buildBinaryTargetGraph(ti, gs, bs, lastNode, linkDeps, binPath);
			lastNode = linkNode;
		}

		foreach (i, pbc; bs.postBuildCommands) {
			auto node = new PhonyNode(this, format("%s-postbuild-%s", ti.pack.name, i+1));
			auto edge = new ShellEdge(this, pbc);
			if (lastNode)
				connect(lastNode, edge, node);
			else
				connect(edge, node);
			lastNode = node;
		}

		// we return the link node and not the last post build node
		// this means that post builds will be processed in parallel of the
		// dependees builds
		return linkNode ? linkNode : lastNode;
	}

	private Node buildBinaryTargetGraph(in ref TargetInfo ti, ref GeneratorSettings gs, BuildSettings bs,
			Node preBuildNode, Node[] linkDeps, out string binPath)
	{
		import dub.compilers.utils : isLinkerFile;
		import std.array : array;
		import std.algorithm : filter;
		import std.file : getcwd;
		import std.format : format;
		import std.path : absolutePath, buildNormalizedPath, relativePath;

		const packPath = ti.pack.path.toString();
		const cwd = buildNormalizedPath(getcwd());
		const buildId = computeBuildID(ti.config, gs, bs);
		const buildDir = buildNormalizedPath(packPath, ".dub", "build", format("graph-%s", buildId));

		// shrink the command lines
		foreach (ref f; bs.sourceFiles) f = shrinkPath(f, cwd);
		foreach (ref p; bs.importPaths) p = shrinkPath(p, cwd);
		foreach (ref p; bs.stringImportPaths) p = shrinkPath(p, cwd);

		Node[] objNodes;
		string[] objFiles;

		foreach (f; bs.sourceFiles.filter!(f => !f.isLinkerFile())) {
			const srcRel = relativePath(f, absolutePath(packPath, cwd));
			const objPath = buildNormalizedPath(buildDir, srcRel)~".o";
			auto src = new FileNode(this, f);
			auto obj = new FileNode(this, objPath);
			auto edge = new CompilerInvocationEdge(this, unitCompile(f, objPath, gs, bs));
			if (preBuildNode) {
				connect([ preBuildNode, cast(Node)src ], edge, [ obj ]);
			}
			else {
				connect(src, edge, obj);
			}
			objNodes ~= obj;
			objFiles ~= objPath;
		}

		// linker
		binPath = buildNormalizedPath(
			packPath, bs.targetPath,
			gs.compiler.getTargetFileName(bs, gs.platform)
		);
		const isStaticLib = bs.targetType == TargetType.staticLibrary ||
				bs.targetType == TargetType.library;

		BuildSettings lbs = bs;
		lbs.sourceFiles = isStaticLib ? [] : bs.sourceFiles.filter!(f => f.isLinkerFile()).array;
		gs.compiler.setTarget(lbs, gs.platform);
		gs.compiler.prepareBuildSettings(lbs, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);

		auto linkNode = new FileNode(this, binPath);
		auto linkEdge = new CompilerInvocationEdge(this,
			gs.compiler.linkerInvocation(lbs, gs.platform, objFiles)
		);

		linkDeps ~= objNodes;
		if (preBuildNode) linkDeps ~= preBuildNode;
		connect(linkDeps, linkEdge, [ linkNode ]);

		return linkNode;
	}

	private bool markNode(Node node)
	{
		assert(node.inEdge);
		if (node.visited) return node.mustBuild;

		bool mustBuild;
		bool hasDepRebuild;

		const mtime = node.timeLastBuild;

		foreach (n; node.inEdge.inNodes)
		{
			const nmt = n.timeLastBuild;
			if (nmt > mtime) {
				mustBuild = true;
			}
			if (n.inEdge && markNode(n)) {
				mustBuild = true;
				hasDepRebuild = true;
			}
		}

		if (mustBuild && !hasDepRebuild) {
			addReady(node.inEdge);
		}
		if (mustBuild) {
			m_numToBuild++;
		}

		node.visited = true;
		node.mustBuild = mustBuild;
		return mustBuild;
	}

	private void build(in uint maxJobs)
	{
		import std.algorithm : map;
		import core.time : dur;
		import std.concurrency : receive, receiveTimeout;

		uint jobs;
		int num=1;

		while (m_readyFirst) {

			auto e = m_readyFirst;

			while (e && jobs < maxJobs) {
				if (!e.inProgress) {
					jobs += e.jobs;
					logInfo("%s/%s building %s", num++, m_numToBuild, e.outNodes.map!"a.name");
					e.process();
				}
				e = e.readyNext;
			}

			void completion(EdgeCompletion ec)
			{
				import std.algorithm : any, all, filter;

				auto edge = m_edges[ec.edgeInd];
				jobs -= edge.jobs;
				removeReady(edge);
				edge.inProgress = false;
				foreach (n; edge.outNodes) {
					n.mustBuild = false;
					foreach (oe; n.outEdges.filter!(e => e.outNodes.any!"a.mustBuild")) {
						if (oe.inNodes.all!(i => !i.mustBuild)) {
							addReady(oe);
						}
					}
				}
			}

			void failure(EdgeFailure ef) {
				throw new Exception("Edge failed");
			}

            // must wait for at least one job
            receive(&completion, &failure);
            // purge all that are already waiting
            while(receiveTimeout(dur!"msecs"(-1), &completion, &failure)) {}
		}
	}

    private void addReady(Edge edge)
    {
        assert (!isReady(edge));

        if (!m_readyFirst) {
            assert(!m_readyLast);
            m_readyFirst = edge;
            m_readyLast = edge;
        }
        else {
            m_readyLast.readyNext = edge;
            edge.readyPrev = m_readyLast;
            m_readyLast = edge;
        }
    }

    private bool isReady(Edge edge) {
        auto e = m_readyFirst;
        while (e) {
            if (e is edge) {
                return true;
            }
            e = e.readyNext;
        }
        return false;
    }

    private void removeReady(Edge edge)
    {
        assert(isReady(edge));

        if (m_readyFirst is m_readyLast) {
            assert(m_readyFirst is edge);
            m_readyFirst = null;
            m_readyLast = null;
        }
        else if (edge is m_readyFirst) {
            m_readyFirst = edge.readyNext;
            m_readyFirst.readyPrev = null;
        }
        else if (edge is m_readyLast) {
            m_readyLast = edge.readyPrev;
            m_readyLast.readyNext = null;
        }
        else {
            auto prev = edge.readyPrev;
            auto next = edge.readyNext;
            prev.readyNext = next;
            next.readyPrev = prev;
        }
        edge.readyNext = null;
        edge.readyPrev = null;
    }

	private void writeGraphviz(in string path)
	{
		import std.stdio : File;

		auto f = File(path, "w");

		f.writeln("digraph G {");

		foreach (k, n; m_nodes) {

			string shape = "";
			if (!n.inEdge) {
				shape = " [shape=box]";
			}
			else if (!n.outEdges.length) {
				shape = " [shape=diamond]";
			}

			f.writefln(`    "%s"%s`, n.name, shape);
		}

		foreach (e; m_edges) {
			foreach (i; e.inNodes) {
				foreach (o; e.outNodes) {
					f.writefln(`    "%s" -> "%s"`, o.name, i.name);
				}
			}
		}

		f.writeln("}");
	}
}


private:

// message structs

struct EdgeCompletion
{
	size_t edgeInd;
	string output;
	immutable(string)[] deps;
}

struct EdgeFailure
{
	size_t edgeInd;
	string output;
}

// graph types

abstract class Node
{
	/// The graph owning this node.
	BuildGraphGenerator graph;
	/// The name of this node. Unique in the graph. Typically a file path.
	string name;
	/// The edge producing this node (null for source files).
	Edge inEdge;
	/// The edges that need this node as input.
	Edge[] outEdges;

	bool mustBuild;
	bool visited;

	this(BuildGraphGenerator graph, in string name) {
		this.graph = graph;
		this.name = name;
		this.graph.m_nodes[name] = this;
	}

	abstract @property SysTime timeLastBuild();
}

/// A node associated with a physical file
class FileNode : Node
{
	/// The modification timestamp of the file
	SysTime mtime = SysTime.min;

	this(BuildGraphGenerator graph, in string name) {
		super(graph, name);
	}

	override @property SysTime timeLastBuild()
	{
		import std.file : timeLastModified;

		return timeLastModified(name, SysTime.min);
	}

}

/// A node not associated with a file.
class PhonyNode : Node
{
	bool done;

	this(BuildGraphGenerator graph, in string name)
	{
		super(graph, name);
	}

	override @property SysTime timeLastBuild()
	{
		return SysTime.min;
	}
}

/// An edge is a link between nodes. In instance it represent a build
/// operation that process input nodes to produce output nodes.
class Edge
{
	BuildGraphGenerator graph;

	Node[] inNodes;
	Node[] outNodes;

	// linked list of edges ready for process
	Edge readyPrev;
	Edge readyNext;

	// ind within graph.m_edges
	size_t ind;
	// jobs consumed by this edge
	uint jobs = 1;
	// whether this edge is currently in progress
	bool inProgress;

	this (BuildGraphGenerator graph)
	{
		this.graph = graph;
		this.ind = this.graph.m_edges.length;
		this.graph.m_edges ~= this;
	}

	/// Process the edge in a new thread and signal the calling thread
	/// either with EdgeCompletion or EdgeFailure message
	abstract void process();
}

/// An edge which is processed by a command
class CmdEdge : Edge
{
	const(string[]) cmd;

	this (BuildGraphGenerator graph, in string[] cmd)
	{
		super(graph);
		this.cmd = cmd;
	}

	override void process()
	{
		import dub.internal.utils : runCommand;
		import std.concurrency : send, spawn, Tid, thisTid;
		import std.process : escapeShellCommand;

		inProgress = true;

		spawn((Tid tid, size_t edgeInd, string cmd) {
			try {
				runCommand(cmd);
				send(tid, EdgeCompletion(edgeInd));
			}
			catch (Exception ex) {
				send(tid, EdgeFailure(edgeInd));
			}
		}, thisTid, ind, escapeShellCommand(cmd));
	}

}
/// An edge which is processed by a shell command
class ShellEdge : Edge
{
	string cmd;

	this (BuildGraphGenerator graph, in string cmd)
	{
		super(graph);
		this.cmd = cmd;
	}

	override void process()
	{
		import dub.internal.utils : runCommand;
		import std.concurrency : send, spawn, Tid, thisTid;

		inProgress = true;

		spawn((Tid tid, size_t edgeInd, string cmd) {
			try {
				runCommand(cmd);
				send(tid, EdgeCompletion(edgeInd));
			}
			catch (Exception ex) {
				send(tid, EdgeFailure(edgeInd));
			}
		}, thisTid, ind, cmd);
	}
}

/// An edge which invokes a compiler
class CompilerInvocationEdge : Edge
{
	CompilerInvocation invocation;

	this (BuildGraphGenerator graph, in CompilerInvocation invocation)
	{
		super(graph);
		this.invocation = invocation;
	}

	override void process()
	{
		import std.concurrency : send, spawn, Tid, thisTid;

		inProgress = true;

		spawn((Tid tid, size_t edgeInd, CompilerInvocation ci) {
			try {
				string output;
				if (invoke(ci, output)) {
					send (tid, EdgeCompletion(edgeInd));
					return;
				}
			}
			catch (Exception ex) {}
			send (tid, EdgeFailure(edgeInd));
		}, thisTid, ind, invocation);
	}
}


// helpers

CompilerInvocation unitCompile(in string src, in string obj, GeneratorSettings gs, BuildSettings bs)
{
	bs.libs = null;
	bs.lflags = null;
	bs.sourceFiles = [ src ];
	bs.targetType = TargetType.object;
	gs.compiler.prepareBuildSettings(bs, BuildSetting.commandLine);
	gs.compiler.setTarget(bs, gs.platform, obj);
	return gs.compiler.invocation(bs, gs.platform);
}

string computeBuildID(in string config, in ref GeneratorSettings gs, in ref BuildSettings bs)
{
	import std.array : join;
	import std.bitmanip : nativeToLittleEndian;
	import std.conv : to;
	import std.digest : toHexString;
	import std.digest.crc : CRC64ECMA;
	import std.format : format;

	CRC64ECMA hash;
	hash.start();
	void addHash(in string[] strings...) {
		foreach (s; strings) { hash.put(cast(ubyte[])s); hash.put(0); }
		hash.put(0);
	}
	void addHashI(int value) {
		hash.put(nativeToLittleEndian(value));
	}
	addHash(bs.versions);
	addHash(bs.debugVersions);
	//addHash(bs.versionLevel);
	//addHash(bs.debugLevel);
	addHash(bs.dflags);
	addHash(bs.lflags);
	addHash((cast(uint)bs.options).to!string);
	addHash(bs.stringImportPaths);
	// addHash(gs.platform.architecture);
	addHash(gs.platform.compilerBinary);
	// addHash(gs.platform.compiler);
	// addHashI(gs.platform.frontendVersion);
	auto hashstr = hash.finish().toHexString().idup;

	return format("%s-%s-%s-%s-%s_%s-%s", config, gs.buildType,
		gs.platform.platform.join("."),
		gs.platform.architecture.join("."),
		gs.platform.compiler,
		gs.platform.frontendVersion, hashstr);
}

string getTargetPath(in ref BuildSettings bs, in ref GeneratorSettings settings)
{
	import std.path : buildNormalizedPath;

	return buildNormalizedPath(bs.targetPath, settings.compiler.getTargetFileName(bs, settings.platform));
}

string shrinkPath(in string path, in string base)
in {
	import std.path : buildNormalizedPath;
	assert(buildNormalizedPath(base) == base);
}
body {
	import std.path : buildNormalizedPath, isAbsolute, relativePath;

	const orig = buildNormalizedPath(path);
	if (!orig.isAbsolute) return orig;
	const rel = relativePath(orig, base);
	return rel.length < orig.length ? rel : orig;
}

unittest {
	assert(shrinkPath("/foo/bar/baz", "/foo") == "bar/baz");
	assert(shrinkPath("/foo/bar/baz", "/foo/baz") == "../bar/baz");
	assert(shrinkPath("/foo/bar/baz", "/bar/") == "/foo/bar/baz");
	assert(shrinkPath("/foo/bar/baz", "/bar/baz") == "/foo/bar/baz");
}

void runTarget(string exePath, in BuildSettings buildsettings, string[] runArgs, GeneratorSettings settings)
{
	import std.algorithm : startsWith;
	import std.array : join;
	import std.conv : to;
	import std.exception : enforce;
	import std.file : chdir, getcwd;
	import std.path : buildNormalizedPath, isAbsolute, relativePath;
	import std.process : execute, spawnProcess, wait;

	assert(buildsettings.targetType == TargetType.executable);

	const cwd = getcwd();
	string rund = cwd;
	if (buildsettings.workingDirectory.length) {
		rund = buildsettings.workingDirectory;
		if (!rund.isAbsolute) rund = cwd ~ rund;
		rund = buildNormalizedPath(rund);
		logDiagnostic("Switching to %s", rund);
		chdir(rund);
	}
	scope(exit) chdir(cwd);

	if (!exePath.isAbsolute) exePath = cwd ~ exePath;
	exePath = buildNormalizedPath(exePath.relativePath(rund));
	version (Posix) {
		if (!exePath.startsWith(".") && !exePath.startsWith("/"))
			exePath = "./" ~ exePath;
	}
	version (Windows) {
		if (!exePath.startsWith(".") && (exePath.length < 2 || exePath[1] != ':'))
			exePath = ".\\" ~ exePath;
	}
	logInfo("Running %s %s", exePath, runArgs.join(" "));
	if (settings.runCallback) {
		auto res = execute(exePath ~ runArgs);
		settings.runCallback(res.status, res.output);
	} else {
		auto pid = spawnProcess(exePath ~ runArgs);
		auto result = pid.wait();
		enforce(result == 0, "Program exited with code "~to!string(result));
	}
}
