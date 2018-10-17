/// helper module for parsing import declarations and find module dependencies.
module dub.generators.imports;

version(DubUseGraphBuild):

import dub.internal.vibecompat.core.log;

/// Retrieve dependencies of the module pointed to by filename.
/// The dependencies returned are paths to the module source files.
string[] moduleDeps(in string filename, in string[] importPaths)
{
    auto mods = importedLocalModules(filename);
    foreach (ref m; mods) {
        m = findDep(m, importPaths);
    }
    return mods;
}

/// Map a module name to its source file path
string findDep (in string mod, in string[] importPaths)
{
    import std.algorithm : splitter;
    import std.file : exists;
    import std.path : buildPath;

    const modBase = buildPath(mod.splitter('.'));
    const mod_d = modBase ~ ".d";
    const mod_di = modBase ~ ".di";
    const mod_pack = buildPath(modBase, "package.d");

    foreach (ip; importPaths) {
        auto dep = buildPath(ip, mod_d);
        if (exists(dep)) return dep;
        dep = buildPath(ip, mod_pack);
        if (exists(dep)) return dep;
        dep = buildPath(ip, mod_di);
        if (exists(dep)) return dep;
    }
    return null;
}

/// Retrieve imported modules from filename.
/// Filter out modules that start with core and std.
string[] importedLocalModules(in string filename)
{
    import dparse.lexer : getTokensForParser, LexerConfig, StringCache;
    import dparse.parser : parseModule;
    import dparse.rollback_allocator : RollbackAllocator;
    import std.algorithm : copy, sort, uniq;
    import std.file : readText;

    const srcCode = readText(filename);

    LexerConfig config;
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto tokens = getTokensForParser(srcCode, config, &cache);

    RollbackAllocator rba;
    auto m = parseModule(tokens, filename, &rba);
    auto visitor = new ImportsVisitor();
    visitor.visit(m);

    auto mods = visitor.mods;
    mods.sort();
    mods.length -= mods.uniq().copy(mods).length;

    return mods;
}

private:

import dparse.ast : ASTVisitor, ImportDeclaration, SingleImport;

class ImportsVisitor : ASTVisitor
{
    alias visit = ASTVisitor.visit;

    string[] mods;

    override void visit(const ImportDeclaration decl)
    {
        import dparse.lexer : str;
        import std.algorithm : map;
        import std.array : join;

        void handle (in SingleImport si)
        {
            const rootPack = si.identifierChain.identifiers[0].text;
            if (rootPack != "std" && rootPack != "core") {
                mods ~= si.identifierChain.identifiers.map!"a.text".join(".");
            }
        }

        foreach (si; decl.singleImports) {
            handle(si);
        }
        if (decl.importBindings && decl.importBindings.singleImport) {
            handle(decl.importBindings.singleImport);
        }

        decl.accept(this);
    }
}
