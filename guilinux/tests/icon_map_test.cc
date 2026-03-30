#include <gtest/gtest.h>
#include "models/IconMap.h"

TEST(IconMap, KnownSFSymbols) {
    EXPECT_EQ(IconMap::toMaterialSymbol("tray"), "\uE156");
    EXPECT_EQ(IconMap::toMaterialSymbol("trash"), "\uE872");
    EXPECT_EQ(IconMap::toMaterialSymbol("paperplane"), "\uE163");
    EXPECT_EQ(IconMap::toMaterialSymbol("archivebox"), "\uE149");
    EXPECT_EQ(IconMap::toMaterialSymbol("doc.text"), "\uE66D");
    EXPECT_EQ(IconMap::toMaterialSymbol("pin"), "\uF10D");
    EXPECT_EQ(IconMap::toMaterialSymbol("pin.fill"), "\uF10D");
    EXPECT_EQ(IconMap::toMaterialSymbol("star"), "\uE838");
}

TEST(IconMap, UnknownFallsBackToLabel) {
    EXPECT_EQ(IconMap::toMaterialSymbol("nonexistent.icon"), "\uE892");
    EXPECT_EQ(IconMap::toMaterialSymbol(""), "\uE892");
}

TEST(IconMap, CompanyIcons) {
    EXPECT_EQ(IconMap::toMaterialSymbol("info.circle"), "\uE88E");
    EXPECT_EQ(IconMap::toMaterialSymbol("banknote"), "\uE227");
    EXPECT_EQ(IconMap::toMaterialSymbol("wrench.and.screwdriver"), "\uE8B8");
    EXPECT_EQ(IconMap::toMaterialSymbol("person.crop.circle.badge.plus"), "\uE7FE");
}
