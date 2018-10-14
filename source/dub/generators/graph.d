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
import dub.package_;
import dub.project;

import std.datetime.systime : SysTime;

class BuildGraphGenerator : ProjectGenerator
{
	// the whole graph nodes and edges
	private Node[string] m_nodes;
	private Edge[] m_edges;

	// postbuild command nodes
	private Node[string] m_preBuildNodes;
	private Node[string] m_postBuildNodes;

	// linked list of edges ready for process
	private Edge m_readyFirst;
	private Edge m_readyLast;

	// a few stats for printing progress
	private uint m_numToBuild;
	private uint m_longestPackName;

	this (Project project) {
		super(project);
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		import std.algorithm : max;
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

			m_longestPackName = max(m_longestPackName, cast(uint)target.length);

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
			node.isTarget = true;
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

		const packName = ti.pack.name;

		if (bs.preBuildCommands.length) {
			auto node = new PhonyNode(this, packName, format("%s-prebuild", ti.pack.name));
			immutable cmds = bs.preBuildCommands.idup;
			auto edge = new CmdsEdge(
				this, ti.pack, gs, bs, format("pre-build command%s", cmds.length > 1 ? "s" : ""), cmds
			);
			m_preBuildNodes[packName] = node;
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

		if (bs.postBuildCommands.length) {
			auto node = new PhonyNode(this, packName, format("%s-postbuild", ti.pack.name));
			immutable cmds = bs.postBuildCommands.idup;
			auto edge = new CmdsEdge(
				this, ti.pack, gs, bs, format("post-build command%s", cmds.length > 1 ? "s" : ""), cmds
			);
			m_postBuildNodes[packName] = node;
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

	private Node buildBinaryTargetGraph(in ref TargetInfo ti, ref GeneratorSettings gs,
			BuildSettings bs, Node preBuildNode, Node[] linkDeps, out string binPath)
	{
		import dub.compilers.utils : isLinkerFile;
		import std.array : array;
		import std.algorithm : filter;
		import std.file : getcwd;
		import std.format : format;
		import std.path : absolutePath, baseName, buildNormalizedPath, relativePath;

		const packName =  ti.pack.name;
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
			auto src = new FileNode(this, packName, f);
			auto obj = new FileNode(this, packName, objPath);
			auto edge = new CompileEdge(this, ti.pack, gs, bs,
					"compiling "~baseName(f), f, objPath);
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

		auto linkNode = new FileNode(this, packName, binPath);
		auto linkEdge = new LinkEdge(this, ti.pack, gs, bs, "linking "~baseName(binPath), objFiles, binPath);

		linkDeps ~= objNodes;
		if (preBuildNode) linkDeps ~= preBuildNode;
		connect(linkDeps, linkEdge, [ linkNode ]);

		return linkNode;
	}

	private bool markNode(Node node)
	{
		import std.path : baseName;

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

		// activate pre-build and post-build if necessary
		if (mustBuild && node.isTarget) {
			auto preB = node.pack in m_preBuildNodes;
			auto postB = node.pack in m_postBuildNodes;

			if (preB) {
				preB.mustBuild = true;
				m_numToBuild++;
				addReady(preB.inEdge);
				foreach (e; preB.outEdges) {
					if (isReady(e)) {
						removeReady(e);
					}
				}
				hasDepRebuild = true;
			}
			if (postB) {
				postB.mustBuild = true;
				m_numToBuild++;
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
		import core.time : dur;
		import std.concurrency : receive, receiveTimeout;
		import std.format : format;

		int numLen(in int num) {
			auto cmp = 10;
			auto res = 1;
			while (cmp <= num) {
				cmp *= 10;
				res += 1;
			}
			return res;
		}

		const maxLen = numLen(m_numToBuild);
		int num=1;

		string spaces(in size_t numSpaces)
		{
			import std.array : replicate;
			return replicate(" ", numSpaces);
		}
		size_t previousLen;
		void printProgress(in string packName, in string desc)
		{
			import std.stdio : stdout;

			if (getLogLevel() < LogLevel.info) return;
			const numStr = format("%s%s", spaces(maxLen-numLen(num)), num++);
			const packStr = format("%s%s", packName, spaces(m_longestPackName-cast(uint)packName.length));
			stdout.writef("\r[ %s/%s %s ] %s%s", numStr, m_numToBuild, packStr, desc,
				spaces(previousLen < desc.length ? 0 : previousLen - desc.length));
			stdout.flush();
			previousLen = desc.length;
		}

		uint jobs;

		scope(exit) logInfo(""); // log new line

		while (m_readyFirst) {

			auto e = m_readyFirst;

			while (e && jobs < maxJobs) {
				if (!e.inProgress) {
					jobs += e.jobs;
					printProgress(e.pack.name, e.desc);
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
				auto edge = m_edges[ef.edgeInd];
				throw new BuildFailedException(edge.desc, ef.cmd, ef.output, ef.code);
			}

			void error(EdgeError ee) {
				auto edge = m_edges[ee.edgeInd];
				throw new Exception(format("%s: %s failed: %s", edge.pack.name, edge.desc, ee.msg));
			}

            // must wait for at least one job
            receive(&completion, &failure, &error);
            // purge all that are already waiting
            while(receiveTimeout(dur!"msecs"(-1), &completion, &failure, &error)) {}
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
		return edge is m_readyFirst || edge.readyPrev !is null || edge.readyNext !is null;
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

		f.writeln("digraph Dub {");
		f.writeln(" rankdir=\"LR\"");

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

/// Exception thrown when a build fails to complete
class BuildFailedException : Exception
{
    string desc;
    string cmd;
    string output;
    int code;

    private this (string desc, string cmd, string output, int code)
    {
        import std.conv : to;

        this.desc = desc;
        this.cmd = cmd;
        this.output = output;
        this.code = code;

        string msg = "\n" ~ desc ~ " failed";
        if (code) msg ~= " with code " ~ code.to!string;
        msg ~= ":\n";

        if (cmd.length) {
            msg ~= cmd ~ "\n";
        }
        if (output.length) {
            msg ~= output ~ "\n";
        }

        super( msg );
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
	int code;
	string cmd;
	string output;
}

struct EdgeError
{
	size_t edgeInd;
	string msg;
}

// graph types

abstract class Node
{
	/// The graph owning this node.
	BuildGraphGenerator graph;
	/// The name of the package this node is part of
	string pack;
	/// The name of this node. Unique in the graph. Typically a file path.
	string name;
	/// whether this node is a target node
	bool isTarget;
	/// The edge producing this node (null for source files).
	Edge inEdge;
	/// The edges that need this node as input.
	Edge[] outEdges;

	bool mustBuild;
	bool visited;

	this(BuildGraphGenerator graph, in string pack, in string name) {
		this.graph = graph;
		this.pack = pack;
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

	this(BuildGraphGenerator graph, in string pack, in string name) {
		super(graph, pack, name);
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

	this(BuildGraphGenerator graph, in string pack, in string name)
	{
		super(graph, pack, name);
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
	/// The graph
	BuildGraphGenerator graph;
	/// The package this edge is part of
	const(Package) pack;
	/// The generator settings of the package
	GeneratorSettings gs;
	/// The build settings of the package
	BuildSettings bs;
	/// A description for the edge
	string desc;

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

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc)
	{
		this.graph = graph;
		this.pack = pack;
		this.gs = gs;
		this.bs = bs;
		this.desc = desc;
		this.ind = this.graph.m_edges.length;
		this.graph.m_edges ~= this;
	}

	/// Process the edge in a new thread and signal the calling thread
	/// either with EdgeCompletion or EdgeFailure message
	abstract void process();
}

/// An edge which is processed by several shell commands
/// (used for prebuild and post build)
class CmdsEdge : Edge
{
	immutable(string)[] cmds;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, immutable(string)[] cmds)
	{
		super(graph, pack, gs, bs, desc);
		this.cmds = cmds;
	}

	override void process()
	{
		import std.concurrency : send, spawn, Tid, thisTid;
		import std.exception : assumeUnique;
		import std.process : pipe, spawnShell, wait;
		import std.stdio : stdin;
		import std.typecons : Yes;

		inProgress = true;

		auto env = prepareCommandsEnvironment(pack, graph.project, gs, bs);

		spawn((Tid tid, size_t edgeInd, immutable(string)[] cmds, immutable(string[string]) env) {
			try {
				string output;
				foreach (cmd; cmds) {
					string buf;
					auto p = pipe();
					auto pid = spawnShell(cmd, stdin, p.writeEnd, p.writeEnd, env);
					foreach (l; p.readEnd.byLineCopy(Yes.keepTerminator)) {
						buf ~= l;
					}
					const code = wait(pid);
					if (code != 0) {
						send(tid, EdgeFailure(edgeInd, code, cmd, output));
					}
					else if (buf.length) {
						output ~= cmd ~ "\n" ~ buf;
					}
				}
				send(tid, EdgeCompletion(edgeInd, output));
			}
			catch (Exception ex) {
				send(tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, cmds, assumeUnique(env));
	}

}

/// An edge which invokes a compiler to compile object
class CompileEdge : Edge
{
	string src;
	string obj;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, in string src, in string obj)
	{
		super(graph, pack, gs, bs, desc);
		this.src = src;
		this.obj = obj;
	}

	override void process()
	{
		import std.array : join;
		import std.concurrency : send, spawn, Tid, thisTid;

		inProgress = true;

		BuildSettings cbs = bs;
		cbs.libs = null;
		cbs.lflags = null;
		cbs.sourceFiles = [ src ];
		cbs.targetType = TargetType.object;
		gs.compiler.prepareBuildSettings(cbs, BuildSetting.commandLine);
		gs.compiler.setTarget(cbs, gs.platform, obj);
		const invocation = gs.compiler.invocation(cbs, gs.platform);

		spawn((Tid tid, size_t edgeInd, CompilerInvocation ci) {
			try {
				int code;
				string output;
				if (invoke(ci, code, output)) {
					send (tid, EdgeCompletion(edgeInd, output));
				}
				else {
					send (tid, EdgeFailure(edgeInd, code, ci.args.join(" "), output));
				}
			}
			catch (Exception ex) {
				send (tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, invocation);
	}
}


/// An edge which invokes a compiler to link executable or library
class LinkEdge : Edge
{
	const(string)[] objs;
	string target;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, in string[] objs, in string target)
	{
		super(graph, pack, gs, bs, desc);
		this.objs = objs;
		this.target = target;
	}

	override void process()
	{
		import dub.compilers.utils : isLinkerFile;
		import std.algorithm : filter;
		import std.array : array, join;
		import std.concurrency : send, spawn, Tid, thisTid;

		inProgress = true;

		const isStaticLib = bs.targetType == TargetType.staticLibrary ||
				bs.targetType == TargetType.library;
		BuildSettings lbs = bs;
		lbs.sourceFiles = isStaticLib ? [] : bs.sourceFiles.filter!(f => f.isLinkerFile()).array;
		gs.compiler.setTarget(lbs, gs.platform);
		gs.compiler.prepareBuildSettings(lbs, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);
		const invocation = gs.compiler.linkerInvocation(lbs, gs.platform, objs);

		spawn((Tid tid, size_t edgeInd, CompilerInvocation ci) {
			try {
				int code;
				string output;
				if (invoke(ci, code, output)) {
					send (tid, EdgeCompletion(edgeInd, output));
				}
				else {
					send (tid, EdgeFailure(edgeInd, code, ci.args.join(" "), output));
				}
			}
			catch (Exception ex) {
				send (tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, invocation);
	}
}


// helpers

string computeBuildID(in string config, in ref GeneratorSettings gs, in ref BuildSettings bs)
{
	import dub.internal.utils : feedDigestData;
	import std.array : join;
	import std.conv : to;
	import std.digest : toHexString;
	import std.digest.crc : CRC64ECMA;
	import std.format : format;

	CRC64ECMA hash;
	hash.start();
	feedDigestData(hash, bs.versions);
	feedDigestData(hash, bs.debugVersions);
	//feedDigestData(hash, bs.versionLevel);
	//feedDigestData(hash, bs.debugLevel);
	feedDigestData(hash, bs.dflags);
	feedDigestData(hash, bs.lflags);
	feedDigestData(hash, (cast(uint)bs.options).to!string);
	feedDigestData(hash, bs.stringImportPaths);
	// feedDigestData(hash, gs.platform.architecture);
	feedDigestData(hash, gs.platform.compilerBinary);
	// feedDigestData(hash, gs.platform.compiler);
	// feedDigestData(hash, gs.platform.frontendVersion);
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
