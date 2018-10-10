/**
	Support for graph based builds.

	That means fine grained builds where only needed modules are rebuilt and
	builds are spread over all cores.
*/
module dub.generators.graph;

import dub.compilers.buildsettings;
import dub.generators.generator;
import dub.project;

class BuildGraphGenerator : ProjectGenerator
{
	// the whole graph nodes and edges
	private Node[string] m_nodes;
	private Edge[] m_edges;

	// the edges ready for process
	private Edge[] m_readyEdges;

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
		m_readyEdges = null;

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
		const buildDir = buildNormalizedPath(packPath, ".dub", format("graph-%s", buildId));

		// shrink the command lines
		foreach (ref f; bs.sourceFiles) f = shrinkPath(f, cwd);
		foreach (ref p; bs.importPaths) p = shrinkPath(p, cwd);
		foreach (ref p; bs.stringImportPaths) p = shrinkPath(p, cwd);

		Node[] objNodes;
		string[] objFiles;

		foreach (f; bs.sourceFiles) {
			const srcRel = relativePath(f, absolutePath(packPath, cwd));
			const objPath = buildNormalizedPath(buildDir, srcRel)~".o";
			auto src = new FileNode(this, f);
			auto obj = new FileNode(this, objPath);
			auto edge = new DgEdge(this, unitCompileDg(f, objPath, gs, bs));
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
		auto linkEdge = new DgEdge(this, {
			gs.compiler.invokeLinker(lbs, gs.platform, objFiles, gs.linkCallback);
		});

		linkDeps ~= objNodes;
		if (preBuildNode) linkDeps ~= preBuildNode;
		connect(linkDeps, linkEdge, [ linkNode ]);

		return linkNode;
	}

}


private:


void delegate() unitCompileDg(in string src, in string obj, GeneratorSettings gs, BuildSettings bs)
{
	bs.libs = null;
	bs.lflags = null;
	bs.sourceFiles = [ src ];
	bs.targetType = TargetType.object;
	gs.compiler.prepareBuildSettings(bs, BuildSetting.commandLine);
	gs.compiler.setTarget(bs, gs.platform, obj);
	return () {
		gs.compiler.invoke(bs, gs.platform, gs.compileCallback);
	};
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


class Node
{
	/// The graph owning this node.
	BuildGraphGenerator graph;
	/// The name of this node. Unique in the graph. Typically a file path.
	string name;
	/// The edge producing this node (null for source files).
	Edge inEdge;
	/// The edges that need this node as input.
	Edge[] outEdges;

	this(BuildGraphGenerator graph, in string name) {
		this.graph = graph;
		this.name = name;
		this.graph.m_nodes[name] = this;
	}
}

/// A node associated with a physical file
class FileNode : Node
{
	/// The modificationtimestamp of the file
	long mtime;

	this(BuildGraphGenerator graph, in string name) {
		super(graph, name);
	}
}

/// A node not associated with a file.
class PhonyNode : Node
{
	this(BuildGraphGenerator graph, in string name)
	{
		super(graph, name);
	}
}

/// An edge is a link between nodes. In instance it represent a build
/// operation that process input nodes to produce output nodes.
class Edge
{
	BuildGraphGenerator graph;

	Node[] inNodes;
	Node[] outNodes;

	this (BuildGraphGenerator graph)
	{
		this.graph = graph;
		this.graph.m_edges ~= this;
	}
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


}

/// An edge which is processed by the execution of a delegate
class DgEdge : Edge
{
	void delegate() dg;

	this (BuildGraphGenerator graph, void delegate() dg)
	{
		super(graph);
		this.dg = dg;
	}
}
