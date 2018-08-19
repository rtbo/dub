/**
	Generator for direct compiler builds.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.generators.build;

import dub.compilers.compiler;
import dub.compilers.utils;
import dub.generators.generator;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.path;
import dub.package_;
import dub.packagemanager;
import dub.project;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.string;
import std.encoding : sanitize;

version(Windows) enum objSuffix = ".obj";
else enum objSuffix = ".o";

class BuildGenerator : ProjectGenerator {
	private {
		PackageManager m_packageMan;
		NativePath[] m_temporaryFiles;
		NativePath m_targetExecutablePath;
	}

	this(Project project)
	{
		super(project);
		m_packageMan = project.packageManager;
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		scope (exit) cleanupTemporaries();

		logInfo("Performing \"%s\" build using %s for %-(%s, %).",
			settings.buildType, settings.platform.compilerBinary, settings.platform.architecture);

		bool any_cached = false;

		NativePath[string] target_paths;

		bool[string] visited;
		void buildTargetRec(string target)
		{
			if (target in visited) return;
			visited[target] = true;

			auto ti = targets[target];

			foreach (dep; ti.dependencies)
				buildTargetRec(dep);

			NativePath[] additional_dep_files;
			auto bs = ti.buildSettings.dup;
			foreach (ldep; ti.linkDependencies) {
				auto dbs = targets[ldep].buildSettings;
				if (bs.targetType != TargetType.staticLibrary && !(bs.options & BuildOption.syntaxOnly)) {
					bs.addSourceFiles(target_paths[ldep].toNativeString());
				} else {
					additional_dep_files ~= target_paths[ldep];
				}
			}
			NativePath tpath;
			if (buildTarget(settings, bs, ti.pack, ti.config, ti.packages, additional_dep_files, tpath))
				any_cached = true;
			target_paths[target] = tpath;
		}

		// build all targets
		auto root_ti = targets[m_project.rootPackage.name];
		if (settings.rdmd || root_ti.buildSettings.targetType == TargetType.staticLibrary) {
			// RDMD always builds everything at once and static libraries don't need their
			// dependencies to be built
			NativePath tpath;
			buildTarget(settings, root_ti.buildSettings.dup, m_project.rootPackage, root_ti.config, root_ti.packages, null, tpath);
		} else {
			buildTargetRec(m_project.rootPackage.name);

			if (any_cached) {
				logInfo("To force a rebuild of up-to-date targets, run again with --force.");
			}
		}
	}

	override void performPostGenerateActions(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		// run the generated executable
		auto buildsettings = targets[m_project.rootPackage.name].buildSettings.dup;
		if (settings.run && !(buildsettings.options & BuildOption.syntaxOnly)) {
			NativePath exe_file_path;
			if (m_targetExecutablePath.empty)
				exe_file_path = getTargetPath(buildsettings, settings);
			else
				exe_file_path = m_targetExecutablePath ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
			runTarget(exe_file_path, buildsettings, settings.runArgs, settings);
		}
	}

	private bool buildTarget(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config, in Package[] packages, in NativePath[] additional_dep_files, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());
		const generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);

		auto build_id = computeBuildID(config, buildsettings, settings);

		if( buildsettings.preBuildCommands.length ){
			logInfo("Running pre-build commands...");
			runScanBuildCommands(buildsettings.preBuildCommands, pack, m_project, settings, buildsettings);
		}

		// make all paths relative to shrink the command line
		string makeRelative(string path) { return shrinkPath(NativePath(path), cwd); }
		foreach (ref f; buildsettings.sourceFiles) f = makeRelative(f);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		// perform the actual build
		bool cached = false;
		if (settings.rdmd) performRDMDBuild(settings, buildsettings, pack, config, target_path);
		else if (settings.direct || !generate_binary) performDirectBuild(settings, buildsettings, pack, config, target_path);
		else cached = performCachedBuild(settings, buildsettings, pack, config, build_id, packages, additional_dep_files, target_path);

		// HACK: cleanup dummy doc files, we shouldn't specialize on buildType
		// here and the compiler shouldn't need dummy doc output.
		if (settings.buildType == "ddox") {
			if ("__dummy.html".exists)
				removeFile("__dummy.html");
			if ("__dummy_docs".exists)
				rmdirRecurse("__dummy_docs");
		}

		// run post-build commands
		if (!cached && buildsettings.postBuildCommands.length) {
			logInfo("Running post-build commands...");
			runBuildCommands(buildsettings.postBuildCommands, pack, m_project, settings, buildsettings);
		}

		return cached;
	}

	private bool performCachedBuild(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config,
		string build_id, in Package[] packages, in NativePath[] additional_dep_files, out NativePath target_binary_path)
	{
		auto cwd = NativePath(getcwd());

		NativePath target_path;
		if (settings.tempBuild) {
			string packageName = pack.basePackage is null ? pack.name : pack.basePackage.name;
			m_targetExecutablePath = target_path = getTempDir() ~ format(".dub/build/%s-%s/%s/", packageName, pack.version_, build_id);
		}
		else target_path = pack.path ~ format(".dub/build/%s/", build_id);

		if (!settings.force && isUpToDate(target_path, buildsettings, settings, pack, packages, additional_dep_files)) {
			logInfo("%s %s: target for configuration \"%s\" is up to date.", pack.name, pack.version_, config);
			logDiagnostic("Using existing build in %s.", target_path.toNativeString());
			target_binary_path = target_path ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
			if (!settings.tempBuild)
				copyTargetFile(target_path, buildsettings, settings);
			return true;
		}

		if (!isWritableDir(target_path, true)) {
			if (!settings.tempBuild)
				logInfo("Build directory %s is not writable. Falling back to direct build in the system's temp folder.", target_path.relativeTo(cwd).toNativeString());
			performDirectBuild(settings, buildsettings, pack, config, target_path);
			return false;
		}

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		// override target path
		auto cbuildsettings = buildsettings;
		cbuildsettings.targetPath = shrinkPath(target_path, cwd);
		buildWithCompiler(settings, cbuildsettings);
		target_binary_path = getTargetPath(cbuildsettings, settings);

		if (!settings.tempBuild)
			copyTargetFile(target_path, buildsettings, settings);

		return false;
	}

	private void performRDMDBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());
		//Added check for existence of [AppNameInPackagejson].d
		//If exists, use that as the starting file.
		NativePath mainsrc;
		if (buildsettings.mainSourceFile.length) {
			mainsrc = NativePath(buildsettings.mainSourceFile);
			if (!mainsrc.absolute) mainsrc = pack.path ~ mainsrc;
		} else {
			mainsrc = getMainSourceFile(pack);
			logWarn(`Package has no "mainSourceFile" defined. Using best guess: %s`, mainsrc.relativeTo(pack.path).toNativeString());
		}

		// do not pass all source files to RDMD, only the main source file
		buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(s => !s.endsWith(".d"))().array();
		settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

		auto generate_binary = !buildsettings.dflags.canFind("-o-");

		// Create start script, which will be used by the calling bash/cmd script.
		// build "rdmd --force %DFLAGS% -I%~dp0..\source -Jviews -Isource @deps.txt %LIBS% source\app.d" ~ application arguments
		// or with "/" instead of "\"
		bool tmp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(NativePath(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max)) ~ "-";
				auto tmpdir = getTempDir()~".rdmd/source/";
				buildsettings.targetPath = tmpdir.toNativeString();
				buildsettings.targetName = rnd ~ buildsettings.targetName;
				m_temporaryFiles ~= tmpdir;
				tmp_target = true;
			}
			target_path = getTargetPath(buildsettings, settings);
			settings.compiler.setTarget(buildsettings, settings.platform);
		}

		logDiagnostic("Application output name is '%s'", settings.compiler.getTargetFileName(buildsettings, settings.platform));

		string[] flags = ["--build-only", "--compiler="~settings.platform.compilerBinary];
		if (settings.force) flags ~= "--force";
		flags ~= buildsettings.dflags;
		flags ~= mainsrc.relativeTo(cwd).toNativeString();

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		logInfo("Running rdmd...");
		logDiagnostic("rdmd %s", join(flags, " "));
		auto rdmd_pid = spawnProcess("rdmd" ~ flags);
		auto result = rdmd_pid.wait();
		enforce(result == 0, "Build command failed with exit code "~to!string(result));

		if (tmp_target) {
			m_temporaryFiles ~= target_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= NativePath(buildsettings.targetPath).parentPath ~ NativePath(f).head;
		}
	}

	private void performDirectBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());

		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
		auto is_static_library = buildsettings.targetType == TargetType.staticLibrary || buildsettings.targetType == TargetType.library;

		// make file paths relative to shrink the command line
		foreach (ref f; buildsettings.sourceFiles) {
			auto fp = NativePath(f);
			if( fp.absolute ) fp = fp.relativeTo(cwd);
			f = fp.toNativeString();
		}

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		// make all target/import paths relative
		string makeRelative(string path) {
			auto p = NativePath(path);
			// storing in a separate temprary to work around #601
			auto prel = p.absolute ? p.relativeTo(cwd) : p;
			return prel.toNativeString();
		}
		buildsettings.targetPath = makeRelative(buildsettings.targetPath);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		bool is_temp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(NativePath(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max));
				auto tmppath = getTempDir()~("dub/"~rnd~"/");
				buildsettings.targetPath = tmppath.toNativeString();
				m_temporaryFiles ~= tmppath;
				is_temp_target = true;
			}
			target_path = getTargetPath(buildsettings, settings);
		}

		buildWithCompiler(settings, buildsettings);

		if (is_temp_target) {
			m_temporaryFiles ~= target_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= NativePath(buildsettings.targetPath).parentPath ~ NativePath(f).head;
		}
	}

	private string computeBuildID(string config, in BuildSettings buildsettings, GeneratorSettings settings)
	{
		import std.digest.digest;
		import std.digest.md;
		import std.bitmanip;

		MD5 hash;
		hash.start();
		void addHash(in string[] strings...) { foreach (s; strings) { hash.put(cast(ubyte[])s); hash.put(0); } hash.put(0); }
		void addHashI(int value) { hash.put(nativeToLittleEndian(value)); }
		addHash(buildsettings.versions);
		addHash(buildsettings.debugVersions);
		//addHash(buildsettings.versionLevel);
		//addHash(buildsettings.debugLevel);
		addHash(buildsettings.dflags);
		addHash(buildsettings.lflags);
		addHash((cast(uint)buildsettings.options).to!string);
		addHash(buildsettings.stringImportPaths);
		addHash(settings.platform.architecture);
		addHash(settings.platform.compilerBinary);
		addHash(settings.platform.compiler);
		addHashI(settings.platform.frontendVersion);
		auto hashstr = hash.finish().toHexString().idup;

		return format("%s-%s-%s-%s-%s_%s-%s", config, settings.buildType,
			settings.platform.platform.join("."),
			settings.platform.architecture.join("."),
			settings.platform.compiler, settings.platform.frontendVersion, hashstr);
	}

	private void copyTargetFile(NativePath build_path, BuildSettings buildsettings, GeneratorSettings settings)
	{
		auto filename = settings.compiler.getTargetFileName(buildsettings, settings.platform);
		auto src = build_path ~ filename;
		logDiagnostic("Copying target from %s to %s", src.toNativeString(), buildsettings.targetPath);
		if (!existsFile(NativePath(buildsettings.targetPath)))
			mkdirRecurse(buildsettings.targetPath);
		hardLinkFile(src, NativePath(buildsettings.targetPath) ~ filename, true);
	}

	private bool isUpToDate(NativePath target_path, BuildSettings buildsettings, GeneratorSettings settings, in Package main_pack, in Package[] packages, in NativePath[] additional_dep_files)
	{
		import std.datetime;

		auto targetfile = target_path ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
		if (!existsFile(targetfile)) {
			logDiagnostic("Target '%s' doesn't exist, need rebuild.", targetfile.toNativeString());
			return false;
		}
		auto targettime = getFileInfo(targetfile).timeModified;

		auto allfiles = appender!(string[]);
		allfiles ~= buildsettings.sourceFiles;
		allfiles ~= buildsettings.importFiles;
		allfiles ~= buildsettings.stringImportFiles;
		// TODO: add library files
		foreach (p; packages)
			allfiles ~= (p.recipePath != NativePath.init ? p : p.basePackage).recipePath.toNativeString();
		foreach (f; additional_dep_files) allfiles ~= f.toNativeString();
		if (main_pack is m_project.rootPackage && m_project.rootPackage.getAllDependencies().length > 0)
			allfiles ~= (main_pack.path ~ SelectedVersions.defaultFile).toNativeString();

		foreach (file; allfiles.data) {
			if (!existsFile(file)) {
				logDiagnostic("File %s doesn't exist, triggering rebuild.", file);
				return false;
			}
			auto ftime = getFileInfo(file).timeModified;
			if (ftime > Clock.currTime)
				logWarn("File '%s' was modified in the future. Please re-save.", file);
			if (ftime > targettime) {
				logDiagnostic("File '%s' modified, need rebuild.", file);
				return false;
			}
		}
		return true;
	}

	/// Output an unique name to represent the source file.
	/// Calls with path that resolve to the same file on the filesystem will return the same,
	/// unless they include different symbolic links (which are not resolved).

	static string pathToObjName(string path)
	{
		import std.digest.crc : crc32Of;
		import std.path : buildNormalizedPath, dirSeparator, relativePath, stripDrive;
		if (path.endsWith(".d")) path = path[0 .. $-2];
		auto ret = buildNormalizedPath(getcwd(), path).replace(dirSeparator, ".");
		auto idx = ret.lastIndexOf('.');
		return idx < 0 ? ret ~ objSuffix : format("%s_%(%02x%)%s", ret[idx+1 .. $], crc32Of(ret[0 .. idx]), objSuffix);
	}

	/// Compile a single source file (srcFile), and write the object to objName.
	static string compileUnit(string srcFile, string objName, BuildSettings bs, GeneratorSettings gs) {
		NativePath tempobj = NativePath(bs.targetPath)~objName;
		string objPath = tempobj.toNativeString();
		bs.libs = null;
		bs.lflags = null;
		bs.sourceFiles = [ srcFile ];
		bs.targetType = TargetType.object;
		gs.compiler.prepareBuildSettings(bs, BuildSetting.commandLine);
		gs.compiler.setTarget(bs, gs.platform, objPath);
		gs.compiler.invoke(bs, gs.platform, gs.compileCallback);
		return objPath;
	}

	private void buildWithCompiler(GeneratorSettings settings, BuildSettings buildsettings)
	{
		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
		auto is_static_library = buildsettings.targetType == TargetType.staticLibrary || buildsettings.targetType == TargetType.library;

		NativePath target_file;
		scope (failure) {
			logDiagnostic("FAIL %s %s %s" , buildsettings.targetPath, buildsettings.targetName, buildsettings.targetType);
			auto tpath = getTargetPath(buildsettings, settings);
			if (generate_binary && existsFile(tpath))
				removeFile(tpath);
		}
		if (settings.buildMode == BuildMode.singleFile && generate_binary) {
			import std.parallelism, std.range : walkLength;

			auto lbuildsettings = buildsettings;
			auto srcs = buildsettings.sourceFiles.filter!(f => !isLinkerFile(f));
			auto objs = new string[](srcs.walkLength);

			void compileSource(size_t i, string src) {
				logInfo("Compiling %s...", src);
				objs[i] = compileUnit(src, pathToObjName(src), buildsettings, settings);
			}

			if (settings.parallelBuild) {
				foreach (i, src; srcs.parallel(1)) compileSource(i, src);
			} else {
				foreach (i, src; srcs.array) compileSource(i, src);
			}

			logInfo("Linking...");
			lbuildsettings.sourceFiles = is_static_library ? [] : lbuildsettings.sourceFiles.filter!(f=> f.isLinkerFile()).array;
			settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);
			settings.compiler.invokeLinker(lbuildsettings, settings.platform, objs, settings.linkCallback);

		/*
			NOTE: for DMD experimental separate compile/link is used, but this is not yet implemented
			      on the other compilers. Later this should be integrated somehow in the build process
			      (either in the dub.json, or using a command line flag)
		*/
		} else if (generate_binary && (settings.buildMode == BuildMode.allAtOnce || settings.compiler.name != "dmd" || is_static_library)) {
			// don't include symbols of dependencies (will be included by the top level target)
			if (is_static_library) buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !f.isLinkerFile()).array;

			// setup for command line
			settings.compiler.setTarget(buildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

			// invoke the compiler
			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);
		} else {
			// determine path for the temporary object file
			string tempobjname = buildsettings.targetName ~ objSuffix;
			NativePath tempobj = NativePath(buildsettings.targetPath) ~ tempobjname;

			// setup linker command line
			auto lbuildsettings = buildsettings;
			lbuildsettings.sourceFiles = lbuildsettings.sourceFiles.filter!(f => isLinkerFile(f)).array;
			if (generate_binary) settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);

			// setup compiler command line
			buildsettings.libs = null;
			buildsettings.lflags = null;
			if (generate_binary) buildsettings.addDFlags("-c", "-of"~tempobj.toNativeString());
			buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !isLinkerFile(f)).array;

			settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);

			if (generate_binary) {
				logInfo("Linking...");
				settings.compiler.invokeLinker(lbuildsettings, settings.platform, [tempobj.toNativeString()], settings.linkCallback);
			}
		}
	}

	private void runTarget(NativePath exe_file_path, in BuildSettings buildsettings, string[] run_args, GeneratorSettings settings)
	{
		if (buildsettings.targetType == TargetType.executable) {
			auto cwd = NativePath(getcwd());
			auto runcwd = cwd;
			if (buildsettings.workingDirectory.length) {
				runcwd = NativePath(buildsettings.workingDirectory);
				if (!runcwd.absolute) runcwd = cwd ~ runcwd;
				logDiagnostic("Switching to %s", runcwd.toNativeString());
				chdir(runcwd.toNativeString());
			}
			scope(exit) chdir(cwd.toNativeString());
			if (!exe_file_path.absolute) exe_file_path = cwd ~ exe_file_path;
			auto exe_path_string = exe_file_path.relativeTo(runcwd).toNativeString();
			version (Posix) {
				if (!exe_path_string.startsWith(".") && !exe_path_string.startsWith("/"))
					exe_path_string = "./" ~ exe_path_string;
			}
			version (Windows) {
				if (!exe_path_string.startsWith(".") && (exe_path_string.length < 2 || exe_path_string[1] != ':'))
					exe_path_string = ".\\" ~ exe_path_string;
			}
			logInfo("Running %s %s", exe_path_string, run_args.join(" "));
			if (settings.runCallback) {
				auto res = execute(exe_path_string ~ run_args);
				settings.runCallback(res.status, res.output);
			} else {
				auto prg_pid = spawnProcess(exe_path_string ~ run_args);
				auto result = prg_pid.wait();
				enforce(result == 0, "Program exited with code "~to!string(result));
			}
		} else
			enforce(false, "Target is a library. Skipping execution.");
	}

	private void cleanupTemporaries()
	{
		foreach_reverse (f; m_temporaryFiles) {
			try {
				if (f.endsWithSlash) rmdir(f.toNativeString());
				else remove(f.toNativeString());
			} catch (Exception e) {
				logWarn("Failed to remove temporary file '%s': %s", f.toNativeString(), e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}
		m_temporaryFiles = null;
	}
}


/** Runs a list of build commands for a particular package and scan for "dub:" lines output

	This function sets all DUB speficic environment variables and scan for
	"dub:" lines output and amend build_settings with the settings passed from
	the commands through these lines.

	Each command get its environment updated by the settings of the previous commands
*/
private void runScanBuildCommands(in string[] commands, in Package pack, in Project proj,
	in GeneratorSettings settings, ref BuildSettings build_settings)
{
	import std.process : Config, pipe, spawnShell, wait;
	import std.stdio : File, stdin, stderr, stdout;

	auto env = prepareCommandsEnvironment(pack, proj, settings, build_settings);

	version(Windows) enum nullFile = "NUL";
	else version(Posix) enum nullFile = "/dev/null";
	else static assert(0);

	// Do not use retainStdout here as the output reading loop would hang forever.
	// Config.retainStderr is not necessary with stderr.
	const config = Config.none;
	const logLevel = getLogLevel();

	auto childrenErr = logLevel >= LogLevel.none ? File(nullFile, "w") : stderr;

	foreach (cmd; commands) {
		logDiagnostic("Running %s", cmd);
		auto p = pipe();
		auto pid = spawnShell(cmd, stdin, p.writeEnd, childrenErr, env, config);

		BuildSettings cmdBs;

		foreach (l; p.readEnd.byLine) {
			stdout.writeln(l);
			enum dubLinePrefix = "dub:";
			enum sdlSyntaxMarker = "sdl:";
			enum jsonSyntaxMarker = "json:";
			if (l.startsWith(dubLinePrefix)) {
				auto content = l[dubLinePrefix.length .. $].idup;
				if (content.startsWith(jsonSyntaxMarker)) {
					content = content[jsonSyntaxMarker.length .. $];
					parseJsonDubLine(cmdBs, content);
				}
				else if (content.startsWith(sdlSyntaxMarker)) {
					content = content[sdlSyntaxMarker.length .. $];
					parseSdlDubLine(cmdBs, content);
				}
				else {
					try {
						parseSdlDubLine(cmdBs, content);
					}
					catch (Exception ex) {
						parseJsonDubLine(cmdBs, content);
					}
				}
			}
		}

		build_settings.add(cmdBs);
		amendBuildSettingsEnvironment(env, cmdBs);

		const exitcode = wait(pid);
		enforce(exitcode == 0, "Command failed with exit code "~to!string(exitcode));
	}
}

// Throw on failure
private void parseJsonDubLine(ref BuildSettings settings, string line)
{
	import dub.internal.vibecompat.core.log : logWarn;
	import dub.internal.vibecompat.data.json : deserializeJson, parseJsonString;
	import std.conv : to;
	import std.format : format;
	import std.meta : Filter;
	import std.traits : EnumMembers;

	alias BS = Filter!(isScannedBuildSetting, EnumMembers!BuildSetting);

	static string buildSwitchCode() {
		string code = "switch(name) {\n";
		foreach (i, bs; BS) {
			enum bsName = bs.to!string;
			code ~= format(
				"case \"%s\": settings.%s ~= deserializeJson!(string[])(value); break;\n",
				bsName, bsName
			);
		}
		code ~= "default: logWarn(\"Ignoring unexpected JSON property: %s\", name); break;";
		return code ~ "}\n";
	}

	enum switchCode = buildSwitchCode();

	auto json = parseJsonString(line);
	foreach(string name, value; json) {
		mixin(switchCode);
	}
}

// Throw on failure
private void parseSdlDubLine(ref BuildSettings settings, string line)
{
	import dub.internal.sdlang : parseSource;
	import dub.internal.vibecompat.core.log : logWarn;
	import std.conv : to;
	import std.format : format;
	import std.meta : Filter;
	import std.traits : EnumMembers;

	alias BS = Filter!(isScannedBuildSetting, EnumMembers!BuildSetting);

	static string buildSwitchCode() {
		string code = "switch(t.fullName) {\n";
		foreach (i, bs; BS) {
			enum bsName = bs.to!string;
			code ~= format(
				"case \"%s\": settings.%s ~= t.values.map!(v => v.get!string).array; break;\n",
				bsName, bsName
			);
		}
		code ~= "default: logWarn(\"Ignoring unexpected SDL property: %s\", t.fullName); break;";
		return code ~ "}\n";
	}

	enum switchCode = buildSwitchCode();

	auto tag = parseSource(line, null);
	foreach(t; tag.all.tags) {
		mixin(switchCode);
	}
}

// Phobos isPowerOf2 is too recent for dub's compiler-compatibility
/** Returns: whether x is a power of 2
*/
private bool isPowerOf2(in int x) pure @safe nothrow @nogc
{
	return x > 0 && !(x & (x - 1));
}

unittest {
	assert(isPowerOf2(1));
	assert(isPowerOf2(2));
	assert(isPowerOf2(4));
	assert(isPowerOf2(8));
	assert(isPowerOf2(16));
	assert(isPowerOf2(32));
	assert(isPowerOf2(64));
	assert(isPowerOf2(128));

	assert(!isPowerOf2(0));
	assert(!isPowerOf2(3));
	assert(!isPowerOf2(36));
	assert(!isPowerOf2(44));
	assert(!isPowerOf2(75));
}

// std.meta.Filter requires this function to be public
/** Returns: whether bs is a build setting that is scanned for output.
*/
bool isScannedBuildSetting(BuildSetting bs)()
{
	import std.algorithm : canFind;
	immutable exclusion = [ BuildSetting.options ];
	return isPowerOf2(cast(int)bs) && !exclusion.canFind(bs);
}

private void amendBuildSettingsEnvironment(ref string[string] env, in BuildSettings settings)
{
	import std.conv : to;
	import std.meta : Filter;
	import std.traits : EnumMembers;

	alias BS = Filter!(isScannedBuildSetting, EnumMembers!BuildSetting);

	foreach (bs; BS) {
		enum bsName = bs.to!string;
		enum envName = buildSettingEnvVarName(bsName);
		const s = mixin("settings."~bsName);
		if (s.length) {
			env[envName] = join(s, " ");
		}
	}
}

private string buildSettingEnvVarName(in string propName) {
	import std.uni : isUpper, toUpper;
	string envName;
	foreach (i, c; propName) {
		if (c.isUpper && i != 0)
			envName ~= "_";
		envName ~= c.toUpper;
	}
	return /+ "DUB_" ~ +/ envName;
}

unittest {
	assert(buildSettingEnvVarName("dflags") == "DFLAGS");
	assert(buildSettingEnvVarName("lflags") == "LFLAGS");
	assert(buildSettingEnvVarName("libs") == "LIBS");
	assert(buildSettingEnvVarName("sourceFiles") == "SOURCE_FILES");
	assert(buildSettingEnvVarName("copyFiles") == "COPY_FILES");
	assert(buildSettingEnvVarName("versions") == "VERSIONS");
	assert(buildSettingEnvVarName("debugVersions") == "DEBUG_VERSIONS");
	assert(buildSettingEnvVarName("importPaths") == "IMPORT_PATHS");
	assert(buildSettingEnvVarName("stringImportPaths") == "STRING_IMPORT_PATHS");
}

private NativePath getMainSourceFile(in Package prj)
{
	foreach (f; ["source/app.d", "src/app.d", "source/"~prj.name~".d", "src/"~prj.name~".d"])
		if (existsFile(prj.path ~ f))
			return prj.path ~ f;
	return prj.path ~ "source/app.d";
}

private NativePath getTargetPath(in ref BuildSettings bs, in ref GeneratorSettings settings)
{
	return NativePath(bs.targetPath) ~ settings.compiler.getTargetFileName(bs, settings.platform);
}

private string shrinkPath(NativePath path, NativePath base)
{
	auto orig = path.toNativeString();
	if (!path.absolute) return orig;
	auto ret = path.relativeTo(base).toNativeString();
	return ret.length < orig.length ? ret : orig;
}

unittest {
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/foo")) == NativePath("bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/foo/baz")) == NativePath("../bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/bar/")) == NativePath("/foo/bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/bar/baz")) == NativePath("/foo/bar/baz").toNativeString());
}

unittest { // issue #1235 - pass no library files to compiler command line when building a static lib
	import dub.internal.vibecompat.data.json : parseJsonString;
	import dub.compilers.gdc : GDCCompiler;
	import dub.platform : determinePlatform;

	version (Windows) auto libfile = "bar.lib";
	else auto libfile = "bar.a";

	auto desc = parseJsonString(`{"name": "test", "targetType": "library", "sourceFiles": ["foo.d", "`~libfile~`"]}`);
	auto pack = new Package(desc, NativePath("/tmp/fooproject"));
	auto pman = new PackageManager(NativePath("/tmp/foo/"), NativePath("/tmp/foo/"), false);
	auto prj = new Project(pman, pack);

	final static class TestCompiler : GDCCompiler {
		override void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback) {
			assert(!settings.dflags[].any!(f => f.canFind("bar")));
		}
		override void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback) {
			assert(false);
		}
	}

	auto comp = new TestCompiler;

	GeneratorSettings settings;
	settings.platform = BuildPlatform(determinePlatform(), ["x86"], "gdc", "test", 2075);
	settings.compiler = new TestCompiler;
	settings.config = "library";
	settings.buildType = "debug";
	settings.tempBuild = true;

	auto gen = new BuildGenerator(prj);
	gen.generate(settings);
}
