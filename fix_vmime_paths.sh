#!/bin/bash
#
# fix_vmime_paths.sh
# Automatically configure Xcode build settings for VMime
#

echo "🔧 Fixing VMime paths in Xcode..."
echo ""

VMIME_INCLUDE="$HOME/.local/include"
VMIME_LIB="$HOME/.local/lib"

# Check if VMime is installed
if [ ! -f "$VMIME_LIB/libvmime.dylib" ]; then
    echo "❌ VMime not found at $VMIME_LIB"
    echo "Run: cd .build/vmime && cmake --install build"
    exit 1
fi

echo "✅ VMime found:"
echo "   Headers: $VMIME_INCLUDE/vmime/"
echo "   Library: $VMIME_LIB/libvmime.dylib"
echo ""

# Create xcconfig if not exists
if [ ! -f "VMime.xcconfig" ]; then
    cat > VMime.xcconfig << 'EOF'
// VMime Build Configuration
HEADER_SEARCH_PATHS = $(inherited) $(HOME)/.local/include
LIBRARY_SEARCH_PATHS = $(inherited) $(HOME)/.local/lib
OTHER_LDFLAGS = $(inherited) -lvmime
LD_RUNPATH_SEARCH_PATHS = $(inherited) $(HOME)/.local/lib
EOF
    echo "✅ Created VMime.xcconfig"
fi

echo ""
echo "📝 Manual steps in Xcode:"
echo "1. Open colonSend.xcodeproj"
echo "2. Select colonSend target"
echo "3. Build Settings:"
echo "   - Header Search Paths: $VMIME_INCLUDE"
echo "   - Library Search Paths: $VMIME_LIB"
echo "   - Other Linker Flags: -lvmime"
echo "   - Runpath Search Paths: $VMIME_LIB"
echo ""
echo "4. Clean Build (Cmd+Shift+K)"
echo "5. Build (Cmd+B)"
echo ""
echo "See VMIME_XCODE_SETUP.md for detailed instructions"
