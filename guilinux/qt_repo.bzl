def _qt_local_repository_impl(ctx):
    qt_root = ctx.os.environ.get("QTDIR") or ctx.os.environ.get("QT_HOME")
    if not qt_root:
        fail("Qt6 not found. Set QTDIR or QT_HOME to your Qt6 install root.")

    qt_root_path = ctx.path(qt_root)
    if not qt_root_path.exists:
        fail("Qt root does not exist: %s" % qt_root)

    lib_dir = qt_root + "/lib"
    if not ctx.path(lib_dir).exists:
        lib_dir = qt_root + "/lib64"
    if not ctx.path(lib_dir).exists:
        fail("Qt lib dir not found under: %s" % qt_root)

    ctx.symlink(lib_dir, "lib")

    include_dir = qt_root + "/include"
    has_include = ctx.path(include_dir).exists
    has_frameworks = ctx.path(lib_dir + "/QtWidgets.framework").exists

    if not has_include and not has_frameworks:
        fail("Qt headers not found. Expected %s or Qt*.framework under %s" % (include_dir, lib_dir))

    if has_include:
        ctx.symlink(include_dir, "include")

    if has_frameworks:
        qt_includes = "qt_includes"
        ctx.symlink(lib_dir + "/QtCore.framework/Headers", qt_includes + "/QtCore")
        ctx.symlink(lib_dir + "/QtGui.framework/Headers", qt_includes + "/QtGui")
        ctx.symlink(lib_dir + "/QtWidgets.framework/Headers", qt_includes + "/QtWidgets")

        includes = [
            "lib/QtCore.framework/Headers",
            "lib/QtCore.framework/Headers/QtCore",
            "lib/QtGui.framework/Headers",
            "lib/QtGui.framework/Headers/QtGui",
            "lib/QtWidgets.framework/Headers",
            "lib/QtWidgets.framework/Headers/QtWidgets",
            "qt_includes",
        ]
        linkopts = [
            "-F" + lib_dir,
            "-Wl,-rpath," + lib_dir,
            "-framework", "QtWidgets",
            "-framework", "QtGui",
            "-framework", "QtCore",
        ]
    else:
        includes = [
            "include",
            "include/QtCore",
            "include/QtGui",
            "include/QtWidgets",
        ]
        linkopts = [
            "-L" + lib_dir,
            "-Wl,-rpath," + lib_dir,
            "-lQt6Widgets",
            "-lQt6Gui",
            "-lQt6Core",
        ]

    build = """
cc_library(
    name = "qt6",
    hdrs = glob(["include/**", "lib/**/Headers/**", "qt_includes/**"]),
    includes = {includes},
    defines = [
        "QT_WIDGETS_LIB",
        "QT_GUI_LIB",
        "QT_CORE_LIB",
    ],
    linkopts = {linkopts},
    visibility = ["//visibility:public"],
)
""".format(includes = includes, linkopts = linkopts)

    ctx.file("BUILD.bazel", build)

qt_local_repository = repository_rule(
    implementation = _qt_local_repository_impl,
    local = True,
    environ = ["QTDIR", "QT_HOME"],
)
