/**
	Compiler settings and abstraction.

	Copyright: © 2013-2016 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.compilers.compiler;

public import dub.compilers.buildsettings;
public import dub.platform : BuildPlatform, matchesSpecification;

import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.path;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.process;


/** Returns a compiler handler for a given binary name.

	The name will be compared against the canonical name of each registered
	compiler handler. If no match is found, the sub strings "dmd", "gdc" and
	"ldc", in this order, will be searched within the name. If this doesn't
	yield a match either, an exception will be thrown.
*/
Compiler getCompiler(string name)
{
	foreach (c; s_compilers)
		if (c.name == name)
			return c;

	// try to match names like gdmd or gdc-2.61
	if (name.canFind("dmd")) return getCompiler("dmd");
	if (name.canFind("gdc")) return getCompiler("gdc");
	if (name.canFind("ldc")) return getCompiler("ldc");

	throw new Exception("Unknown compiler: "~name);
}

/** Registers a new compiler handler.

	Note that by default `DMDCompiler`, `GDCCompiler` and `LDCCompiler` are
	already registered at startup.
*/
void registerCompiler(Compiler c)
{
	s_compilers ~= c;
}


/// Represent an invocation of a compiler
/// with optional support for an argument file (aka RSP - response file).
struct CompilerInvocation
{
	/// invocation arguments. args[0] is the compiler binary.
	immutable(string)[] args;

	/// null if rsp file is not supported or not desired, in such case the args
	/// must be passed verbatim to the compiler, otherwise a format
	/// containing "%s" as placeholder for a filename to be written
	/// with args[1 .. $] as content (one arg per line)
	string rspFormat;

	/// a dependency file produced by the invocation
	string depfile;
}

interface Compiler {
	/// Returns the canonical name of the compiler (e.g. "dmd").
	@property string name() const;

	/** Determines the build platform properties given a set of build settings.

		This will invoke the compiler to build a platform probe file, which
		determines the target build platform's properties during compile-time.

		See_Also: `dub.compilers.utils.generatePlatformProbeFile`
	*/
	BuildPlatform determinePlatform(ref BuildSettings settings, string compiler_binary, string arch_override = null);

	/// Replaces high level fields with low level fields and converts
	/// dmd flags to compiler-specific flags
	void prepareBuildSettings(ref BuildSettings settings, BuildSetting supported_fields = BuildSetting.all) const;

	/// Removes any dflags that match one of the BuildOptions values and populates the BuildSettings.options field.
	void extractBuildOptions(ref BuildSettings settings) const;

	/// Computes the full file name of the generated binary.
	string getTargetFileName(in BuildSettings settings, in BuildPlatform platform) const;

	/// Adds the appropriate flag to set a target path
	void setTarget(ref BuildSettings settings, in BuildPlatform platform, string targetPath = null) const;

	/// Invokes the compiler using the given flags
	void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback);

	/// Invokes the underlying linker directly
	void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback);

	/// Convert linker flags to compiler format
	string[] lflagsToDFlags(in string[] lflags) const;

	/// Get arguments for a deferred invocation
	CompilerInvocation invocation(in BuildSettings settings, in BuildPlatform platform);

	/// Get arguments for a deferred linker invocation
	CompilerInvocation linkerInvocation(in BuildSettings settings, in BuildPlatform platform, in string[] objects);

	/** Runs a tool and provides common boilerplate code.

		This method should be used by `Compiler` implementations to invoke the
		compiler or linker binary.
	*/
	protected final void invokeTool(string[] args, void delegate(int, string) output_callback)
	{
		import std.string;

		int status;
		if (output_callback) {
			auto result = executeShell(escapeShellCommand(args));
			output_callback(result.status, result.output);
			status = result.status;
		} else {
			auto compiler_pid = spawnShell(escapeShellCommand(args));
			status = compiler_pid.wait();
		}

		version (Posix) if (status == -9) {
			throw new Exception(format("%s failed with exit code %s. This may indicate that the process has run out of memory.",
				args[0], status));
		}
		enforce(status == 0, format("%s failed with exit code %s.", args[0], status));
	}

	/// Compiles platform probe file with the specified compiler and parses its output.
	protected final BuildPlatform probePlatform(string compiler_binary, string[] args, string arch_override)
	{
		import std.string : format;
		import dub.compilers.utils : generatePlatformProbeFile, readPlatformProbe;

		auto fil = generatePlatformProbeFile();

		auto result = executeShell(escapeShellCommand(compiler_binary ~ args ~ fil.toNativeString()));
		enforce(result.status == 0, format("Failed to invoke the compiler %s to determine the build platform: %s",
				compiler_binary, result.output));

		auto build_platform = readPlatformProbe(result.output);
		build_platform.compilerBinary = compiler_binary;

		if (build_platform.compiler != this.name) {
			logWarn(`The determined compiler type "%s" doesn't match the expected type "%s". This will probably result in build errors.`,
				build_platform.compiler, this.name);
		}

		// Hack: see #1059
		// When compiling with --arch=x86_mscoff build_platform.architecture is equal to ["x86"] and canFind below is false.
		// This hack prevents unnesessary warning 'Failed to apply the selected architecture x86_mscoff. Got ["x86"]'.
		// And also makes "x86_mscoff" available as a platform specifier in the package recipe
		if (arch_override == "x86_mscoff")
			build_platform.architecture ~= arch_override;
		if (arch_override.length && !build_platform.architecture.canFind(arch_override)) {
			logWarn(`Failed to apply the selected architecture %s. Got %s.`,
				arch_override, build_platform.architecture);
		}

		return build_platform;
	}
}

/// Exception thrown by invoke when the compiler returns non-zero code
class CompilerInvocationFailed : Exception
{
	/// invocation that returned non-zero
	CompilerInvocation invocation;
	/// compiler output (stdout and stderr)
	string output;

	this (CompilerInvocation invocation, string output)
	{
		this.invocation = invocation;
		this.output = output;

		super(
			"Compiler invocation failed:\n" ~
			invocation.args.join(" ") ~ "\n" ~
			output
		);
	}
}

/// Perform the compiler invocation
bool invoke(in CompilerInvocation ci, out int code, out string output)
{
	import dub.internal.utils : getTempFile;
	import std.exception : enforce;
	import std.file : remove, write;
	import std.format : format;
	import std.process : pipe, spawnProcess, wait;
	import std.stdio : File, stdin;
	import std.typecons : Yes;

	string resFile;
	const(string)[] args = ci.args;
	if (ci.rspFormat.length) {
		resFile = getTempFile("dub-build", ".rsp").toNativeString();
		auto f = File(resFile, "w");
		foreach (a; args[1 .. $]) {
			f.writeln(a);
		}
		args = [ args[0], format(ci.rspFormat, resFile) ];
	}

	auto p = pipe();
	auto pid = spawnProcess(args, stdin, p.writeEnd, p.writeEnd);
	foreach (l; p.readEnd.byLineCopy(Yes.keepTerminator)) {
		output ~= l;
	}
	code = wait(pid);
	if (resFile) remove(resFile);
	return code == 0;
}

private {
	Compiler[] s_compilers;

	auto escapeArgs(in string[] args)
	{
		return args.map!(s => s.canFind(' ') ? "\""~s~"\"" : s);
	}
}

