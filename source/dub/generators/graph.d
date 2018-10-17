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
	private uint m_longestPackLen;

	// per package logs to track if cmd line has changed and module dependencies
	private EdgeLog[string] m_edgeLogs;

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
		m_longestPackLen = 0;
		m_edgeLogs = null;

		enforce(!settings.rdmd, "RDMD not supported for graph based builds");

		scope(exit) cleanUpLogs();

		// step 1: recursive descent to build the dependency graph

		string[string] targetPaths;
		Node[string] targetNodes;

		Node buildTargetGraphRec(in string target)
		{
			auto pn = target in targetNodes;
			if (pn) return *pn;

			m_longestPackLen = max(m_longestPackLen, cast(uint)target.length);

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

	private EdgeLog edgeLog (Edge edge)
	{
		import std.path : buildNormalizedPath;

		const path = edge.buildDir;
		auto lp = path in m_edgeLogs;
		if (lp) return *lp;
		auto l = new EdgeLog(path);
		m_edgeLogs[path] = l;
		return l;
	}

	private void cleanUpLogs()
	{
		foreach (k, l; m_edgeLogs) {
			l.close();
		}
		m_edgeLogs = null;
	}

	private void addDeps(Edge edge, in string[] deps)
	{
		import std.algorithm : canFind, map;

		foreach (d; deps) {
			if (edge.inNodes.map!"a.name".canFind(d)) continue;

			auto np = d in m_nodes;
			Node n;
			if (np) {
				n = *np;
			}
			else {
				n = new FileNode(this, edge.pack.name, d);
				m_nodes[d] = n;
			}
			n.outEdges ~= edge;
			edge.inNodes ~= n;
		}
	}

	private Node buildTargetGraph(in ref TargetInfo ti, ref GeneratorSettings gs,
				BuildSettings bs, Node[] linkDeps, out string binPath)
	{
		import std.file : mkdirRecurse;
		import std.format : format;
		import std.path : buildNormalizedPath;

		// most can be in parallel, but there is a minimal sequence:
		// - prebuild commands (each in sequence)
		// - actual build and link
		// - postbuild commands (each in sequence)
		// this sequence is tracked with lastNode
		Node lastNode;
		Node linkNode;

		const packName = ti.pack.name;
		const packPath = ti.pack.path.toString();
		const buildId = computeBuildID(ti.config, gs, bs);
		const buildDir = buildNormalizedPath(packPath, ".dub", "build", format("graph-%s", buildId));
		mkdirRecurse(buildDir);

		if (bs.preBuildCommands.length) {
			auto node = new PhonyNode(this, packName, format("%s-prebuild", ti.pack.name));
			immutable cmds = bs.preBuildCommands.idup;
			auto edge = new CmdsEdge(
				this, ti.pack, gs, bs,
				format("pre-build command%s", cmds.length > 1 ? "s" : ""),
				buildDir, cmds
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

			linkNode = buildBinaryTargetGraph(ti, gs, bs, lastNode, linkDeps, buildDir, binPath);
			lastNode = linkNode;
		}

		if (bs.postBuildCommands.length) {
			auto node = new PhonyNode(this, packName, format("%s-postbuild", ti.pack.name));
			immutable cmds = bs.postBuildCommands.idup;
			auto edge = new CmdsEdge(
				this, ti.pack, gs, bs,
				format("post-build command%s", cmds.length > 1 ? "s" : ""),
				buildDir, cmds
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
			BuildSettings bs, Node preBuildNode, Node[] linkDeps, in string buildDir,
			out string binPath)
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
					"compiling "~baseName(f), buildDir, f, objPath);
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
		auto linkEdge = new LinkEdge(
			this, ti.pack, gs, bs, "linking "~baseName(binPath), buildDir,
			objFiles, binPath
		);

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
		if (!node.inEdge) {
			assert(node.exists, node.name~" does not exist");
			node.mustBuild = false;
			return false;
		}

		bool mustBuild;
		bool hasDepRebuild;

		const mtime = node.timeLastBuild;
		auto log = edgeLog(node.inEdge);
		auto entry = log.entry(node.name);
		if (entry && entry.deps) {
			addDeps(node.inEdge, entry.deps);
		}

		SysTime mostRecentDep;

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
            if (mostRecentDep < nmt) mostRecentDep = nmt;
		}

		node.checkEntry(entry, mostRecentDep);

		// activate pre-build and post-build if target must be rebuilt
		if (mustBuild && node.isTarget) {
			auto preB = node.pack in m_preBuildNodes;
			auto postB = node.pack in m_postBuildNodes;

			if (preB && !preB.mustBuild) {
				preB.mustBuild = true;
				m_numToBuild++;
				addReady(preB.inEdge);
				foreach (e; preB.outEdges) {
					if (isReady(e)) removeReady(e);
				}
				hasDepRebuild = true;
			}
			if (postB && !postB.mustBuild) {
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

		uint jobs;

		auto console = new BuildConsole(m_numToBuild, m_longestPackLen);
		scope(exit) console.close();

		while (m_readyFirst) {

			auto e = m_readyFirst;

			while (e && jobs < maxJobs) {
				if (!e.inProgress && (!console.locked || !e.locksConsole)) {
					jobs += e.jobs;
					console.printProgress(e.pack.name, e.desc);
					e.process();
					if (e.locksConsole)
						console.lock();
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
					assert(n.exists, edge.desc ~" did not produce "~n.name);
					n.postBuild(ec.deps);
					foreach (oe; n.outEdges.filter!(e => e.outNodes.any!"a.mustBuild")) {
						if (oe.inNodes.all!(i => !i.mustBuild)) {
							addReady(oe);
						}
					}
				}
				if (ec.output.length) {
					const msg = format(
						"\nmessage from %s - %s:\n%s\n%s",
						edge.pack.name, edge.desc, ec.cmd, ec.output
					);
					console.printMessage(msg);
				}
				if (console.locked && edge.locksConsole) {
					console.unlock();
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
	string cmd;
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

	abstract @property bool exists();

	abstract @property SysTime timeLastBuild();

	void checkEntry(in EdgeLog.Entry* entry, SysTime mostRecentDep) {}

	void postBuild(in string[] deps)
	{
		mustBuild = false;
	}
}

/// A node associated with a physical file
class FileNode : Node
{
	/// The modification timestamp of the file
	SysTime mtime = SysTime.min;

	this(BuildGraphGenerator graph, in string pack, in string name) {
		super(graph, pack, name);
	}

	override @property bool exists()
	{
		import std.file : file_exists = exists;

		return file_exists(name);
	}

	override @property SysTime timeLastBuild()
	{
		import std.file : timeLastModified;

		return timeLastModified(name, SysTime.min);
	}

	override void checkEntry(in EdgeLog.Entry* entry, SysTime mostRecentDep)
	{
		if (entry && (mostRecentDep.stdTime > entry.mtime || inEdge.hashCode != entry.hash)) {
			mustBuild = true;
		}
		else if (!entry) {
			// if we can't link this to a previous build, we follow conservative
			// rules
			mustBuild = true;
		}

	}

	override void postBuild(in string[] deps)
	{
		super.postBuild(deps);

		auto log = graph.edgeLog(inEdge);
		const entry = EdgeLog.Entry(timeLastBuild.stdTime, inEdge.hashCode, deps);
		log.setEntry(name, entry);
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

	override @property bool exists()
	{
		return true;
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
	/// The build directory
	string buildDir;

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
			BuildSettings bs, in string desc, in string buildDir)
	{
		this.graph = graph;
		this.pack = pack;
		this.gs = gs;
		this.bs = bs;
		this.desc = desc;
		this.buildDir = buildDir;
		this.ind = this.graph.m_edges.length;
		this.graph.m_edges ~= this;
	}

	/// Returns whether this edge should have exclusive access on the console.
	@property bool locksConsole() {
		return false;
	}

	/// Process the edge in a new thread and signal the calling thread
	/// either with EdgeCompletion or EdgeFailure message
	abstract void process();

	/// Compute hash code to uniquely identify the edge parameters
	abstract @property ulong hashCode();
}

/// An edge which is processed by several shell commands
/// (used for prebuild and post build)
class CmdsEdge : Edge
{
	immutable(string)[] cmds;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, in string buildDir, immutable(string)[] cmds)
	{
		super(graph, pack, gs, bs, desc, buildDir);
		this.cmds = cmds;
	}

	override @property bool locksConsole()
	{
		return true;
	}

	override void process()
	{
		import dub.internal.utils : nulFile;
		import std.concurrency : send, spawn, Tid, thisTid;
		import std.exception : assumeUnique;
		import std.process : Config, pipe, spawnShell, wait;
		import std.stdio : stdin, stdout, stderr;
		import std.typecons : Yes;

		inProgress = true;

		auto env = prepareCommandsEnvironment(pack, graph.project, gs, bs);

		spawn((Tid tid, size_t edgeInd, immutable(string)[] cmds, immutable(string[string]) env) {
			try {
				foreach (cmd; cmds) {
					enum conf = Config.retainStdin | Config.retainStdout | Config.retainStderr;
					auto pid = spawnShell(cmd, stdin, stdout, stderr, env, conf);
					const code = wait(pid);
					if (code != 0) {
						send(tid, EdgeFailure(edgeInd, code, cmd, null));
					}
				}
				send(tid, EdgeCompletion(edgeInd));
			}
			catch (Exception ex) {
				send(tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, cmds, assumeUnique(env));
	}

	override @property ulong hashCode()
	{
		import dub.internal.utils : feedDigestData;
		import std.digest.crc : CRC64ECMA;

		CRC64ECMA hash;
		hash.start();
		hash.feedDigestData(cmds);
		const bytes = hash.finish();
		return *(cast(const(ulong)*)&bytes[0]);
	}
}

/// An edge which invokes a compiler to compile object
class CompileEdge : Edge
{
	string src;
	string obj;

	CompilerInvocation invocation;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, in string buildDir, in string src, in string obj)
	{
		super(graph, pack, gs, bs, desc, buildDir);
		this.src = src;
		this.obj = obj;
	}

	private void prepareInvocation()
	{
		if (invocation.args.length) return;

		BuildSettings cbs = bs;
		cbs.libs = null;
		cbs.lflags = null;
		cbs.sourceFiles = [ src ];
		cbs.targetType = TargetType.object;
		gs.compiler.prepareBuildSettings(cbs, BuildSetting.commandLine);
		gs.compiler.setTarget(cbs, gs.platform, obj);
		invocation = gs.compiler.invocation(cbs, gs.platform);
	}

	override void process()
	{
		import std.array : join;
		import std.concurrency : send, spawn, Tid, thisTid;
		import std.file : mkdirRecurse;
		import std.path : dirName;

		inProgress = true;

		prepareInvocation();

		spawn((Tid tid, size_t edgeInd, CompilerInvocation ci, in string src,
				immutable(string[]) importPaths)
		{
			try {
				int code;
				string output;
				const cmd = ci.args.join(" ");
				if (ci.depfile.length) {
					mkdirRecurse(dirName(ci.depfile));
				}
				if (invoke(ci, code, output)) {
					// would normally use dmd -deps option here, but the tests I did show it really buggy:
					//  - ~3000 lines exported for each file
					//  - builds about 10x slower (may be due to IO or to my code processing of the too many lines)
					//  - prints lines for every module without possibility to filter out core and std
					//  - likely perform recursive analysis, which is not needed here
					//  - occasional ICE
					// so I fallback on libdparse based import parsing
					import dub.generators.imports : moduleDeps;
					import std.exception : assumeUnique;

					immutable deps = assumeUnique(moduleDeps(src, importPaths));

					send (tid, EdgeCompletion(edgeInd, cmd, output, deps));
				}
				else {
					send (tid, EdgeFailure(edgeInd, code, cmd, output));
				}
			}
			catch (Exception ex) {
				send (tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, invocation, src, bs.importPaths.idup);
	}

	override @property ulong hashCode()
	{
		import dub.internal.utils : feedDigestData;
		import std.digest.crc : CRC64ECMA;

		prepareInvocation();

		CRC64ECMA hash;
		hash.start();
		hash.feedDigestData(invocation.args);
		const bytes = hash.finish();
		return *(cast(const(ulong)*)&bytes[0]);
	}
}


/// An edge which invokes a compiler to link executable or library
class LinkEdge : Edge
{
	const(string)[] objs;
	string target;

	CompilerInvocation invocation;

	this (BuildGraphGenerator graph, const(Package) pack, GeneratorSettings gs,
			BuildSettings bs, in string desc, in string buildDir, in string[] objs, in string target)
	{
		super(graph, pack, gs, bs, desc, buildDir);
		this.objs = objs;
		this.target = target;
	}

	private void prepareInvocation()
	{
		import dub.compilers.utils : isLinkerFile;
		import std.algorithm : filter;
		import std.array : array;

		if (invocation.args.length) return;

		const isStaticLib = bs.targetType == TargetType.staticLibrary ||
				bs.targetType == TargetType.library;
		BuildSettings lbs = bs;
		lbs.sourceFiles = isStaticLib ? [] : bs.sourceFiles.filter!(f => f.isLinkerFile()).array;
		gs.compiler.setTarget(lbs, gs.platform);
		gs.compiler.prepareBuildSettings(lbs, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);
		invocation = gs.compiler.linkerInvocation(lbs, gs.platform, objs);
	}

	override void process()
	{
		import std.array : join;
		import std.concurrency : send, spawn, Tid, thisTid;

		inProgress = true;

		prepareInvocation();

		spawn((Tid tid, size_t edgeInd, CompilerInvocation ci) {
			try {
				int code;
				string output;
				const cmd = ci.args.join(" ");
				if (invoke(ci, code, output)) {
					send (tid, EdgeCompletion(edgeInd, cmd, output));
				}
				else {
					send (tid, EdgeFailure(edgeInd, code, cmd, output));
				}
			}
			catch (Exception ex) {
				send (tid, EdgeError(edgeInd, ex.msg));
			}
		}, thisTid, ind, invocation);
	}

	override @property ulong hashCode()
	{
		import dub.internal.utils : feedDigestData;
		import std.digest.crc : CRC64ECMA;

		prepareInvocation();

		CRC64ECMA hash;
		hash.start();
		hash.feedDigestData(invocation.args);
		const bytes = hash.finish();
		return *(cast(const(ulong)*)&bytes[0]);
	}
}

// edge log

class EdgeLog
{
	import std.stdio : File;

	enum fileName = ".edge_log";

	struct Entry {
		long mtime;
		ulong hash;
		const(string)[] deps;
	}

	private Entry[string] entries;
	private string path;
    private File file;
    private uint dups;

    this (string packPath)
    {
		import std.file : exists;
        import std.format : formattedRead;
		import std.path : buildPath;

		path = buildPath(packPath, fileName);

		if (!path.exists) {
			file = File(path, "w");
			file.reopen(path, "a+");
		}
		else {
        	file = File(path, "a+");
		}

        foreach (l; file.byLineCopy) {
            Entry e;
            string output;
            string[] deps;
            formattedRead!`"%s" %s %s %s`(l, output, e.mtime, e.hash, deps);
            e.deps = deps;
            auto ep = output in entries;
            if (ep) {
                *ep = e;
                dups++;
            }
            else {
                entries[output] = e;
            }
        }
    }

    void close()
    {
        if (dups*10 > entries.length) {
            file.reopen(path, "w");
            foreach (output, e; entries) {
				writeEntry(output, e);
            }
            file.close();
        }
		else {
			file.close();
		}
    }

    const(Entry)* entry(in string output) const
    {
        return output in entries;
    }

    void setEntry(in string output, in Entry entry)
    {
        auto ep = output in entries;
        if (ep) {
            *ep = entry;
            dups++;
        }
        else {
            entries[output] = entry;
        }
		writeEntry(output, entry);
		file.flush();
    }

	private void writeEntry(in string output, in Entry entry)
	{
		file.writefln(`"%s" %s %s %s`, output, entry.mtime, entry.hash, entry.deps);
	}
}


// helpers

string computeBuildID(in string config, ref GeneratorSettings gs, in ref BuildSettings bs)
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
	feedDigestData(hash, gs.compiler.frontendVersion(gs.platform));
	// feedDigestData(hash, gs.platform.compiler);
	// feedDigestData(hash, gs.platform.frontendVersion);
	auto hashstr = hash.finish().toHexString();

	return format("%s-%s-%s-%s_%s-%s", config, gs.buildType,
		gs.platform.architecture.join("."),
		gs.compiler.name,
		gs.compiler.version_(gs.platform), hashstr);
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

class BuildConsole
{
	private enum progLogLevel = LogLevel.info;
	private enum printSameLine = true;

	private bool locked;
	private bool hadNL = true;
	private uint num = 1;
	private uint numToBuild;
	private uint longestPackLen;
	private uint maxNumLen;
	private size_t previousLen;
	private string progBuf;
	private string[] msgBuf;


	this(in uint numToBuild, in uint longestPackLen)
	{
		this.numToBuild = numToBuild;
		this.longestPackLen = longestPackLen;
		maxNumLen = numLen(numToBuild);
	}

	void close()
	{
		ensureNL();
	}

	void lock() in (!locked)
	{
		locked = true;
		ensureNL();
	}

	void unlock() in (locked)
	{
		import std.stdio : stdout;

		locked = false;
		ensureNL();
		foreach (m; msgBuf) {
			log(progLogLevel, m);
		}
		msgBuf = null;
		if (progBuf) {
			stdout.write(progBuf);
			stdout.flush();
			static if (printSameLine) hadNL = false;
		}
		progBuf = null;
	}

	void printProgress(in string packName, in string desc)
	{
		import std.format : format;
		import std.stdio : stdout;

		if (getLogLevel() < progLogLevel) return;

		const numStr = format("%s%s", spaces(maxNumLen-numLen(num)), num++);
		const packStr = format("%s%s", packName, spaces(longestPackLen-cast(uint)packName.length));

		static if (printSameLine) {
			enum fmt = "\r[ %s/%s %s ] %s%s";
		} else {
			enum fmt = "[ %s/%s %s ] %s%s\n";
		}

		const msg = format(fmt, numStr, numToBuild, packStr, desc,
			spaces(previousLen < desc.length ? 0 : previousLen - desc.length));

		if (!locked) {
			stdout.write(msg);
			stdout.flush();
			static if (printSameLine) hadNL = false;
		} else {
			progBuf = msg;
		}

		previousLen = desc.length;
	}

	void printMessage(in string msg)
	{
		if (locked) {
			msgBuf ~= msg;
		}
		else {
			log(progLogLevel, msg);
			hadNL = true;
		}
	}

	private void ensureNL()
	{
		if (!hadNL) {
			log(progLogLevel, "");
			hadNL = true;
		}
	}

	private static int numLen(in int num) pure {
		auto cmp = 10;
		auto res = 1;
		while (cmp <= num) {
			cmp *= 10;
			res += 1;
		}
		return res;
	}
	private static string spaces(in size_t numSpaces) pure
	{
		import std.array : replicate;
		return replicate(" ", numSpaces);
	}

}
