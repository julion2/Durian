#!/bin/bash

echo "🔍 Verifiziere Build Settings..."
echo ""

# Check project file
if [ ! -f "colonSend.xcodeproj/project.pbxproj" ]; then
    echo "❌ Project file not found"
    exit 1
fi

echo "✅ Project file found"

# Check for VMime settings
HEADER_PATHS=$(grep -c "HEADER_SEARCH_PATHS.*HOME.*local" colonSend.xcodeproj/project.pbxproj)
LIBRARY_PATHS=$(grep -c "LIBRARY_SEARCH_PATHS.*HOME.*local" colonSend.xcodeproj/project.pbxproj)
LINKER_FLAGS=$(grep -c "OTHER_LDFLAGS.*lvmime" colonSend.xcodeproj/project.pbxproj)
RUNPATH=$(grep -c "LD_RUNPATH_SEARCH_PATHS.*HOME.*local" colonSend.xcodeproj/project.pbxproj)

echo ""
echo "📊 Build Settings Status:"
echo "  Header Search Paths: $HEADER_PATHS/2 configs"
echo "  Library Search Paths: $LIBRARY_PATHS/2 configs"
echo "  Linker Flags (-lvmime): $LINKER_FLAGS/2 configs"
echo "  Runpath Search Paths: $RUNPATH/2 configs"
echo ""

if [ $HEADER_PATHS -eq 2 ] && [ $LIBRARY_PATHS -eq 2 ] && [ $LINKER_FLAGS -eq 2 ] && [ $RUNPATH -eq 2 ]; then
    echo "✅ Alle Build Settings korrekt konfiguriert!"
    echo ""
    echo "🚀 Nächster Schritt:"
    echo "   1. Öffne Xcode: open colonSend.xcodeproj"
    echo "   2. Clean Build: Cmd+Shift+K"
    echo "   3. Build: Cmd+B"
    echo ""
else
    echo "⚠️  Einige Build Settings fehlen noch"
    echo "   Siehe VMIME_XCODE_SETUP.md für manuelle Konfiguration"
fi

# Check VMime installation
echo "📦 VMime Installation:"
if [ -f "$HOME/.local/lib/libvmime.dylib" ]; then
    echo "  ✅ Library: $HOME/.local/lib/libvmime.dylib"
else
    echo "  ❌ Library nicht gefunden!"
fi

if [ -f "$HOME/.local/include/vmime/vmime.hpp" ]; then
    echo "  ✅ Headers: $HOME/.local/include/vmime/"
else
    echo "  ❌ Headers nicht gefunden!"
fi

echo ""
