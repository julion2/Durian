#pragma once

#include <QHash>
#include <QString>

// Maps SF Symbol names (from profiles.pkl) to Material Symbols Unicode codepoints.
class IconMap {
public:
    static QString toMaterialSymbol(const QString &sfSymbol) {
        static const QHash<QString, QString> map = {
            // Common folder icons
            {"tray",                          "\uE156"},  // inbox
            {"envelope.badge",                "\uE0BE"},  // mark_email_unread
            {"paperplane",                    "\uE163"},  // send
            {"doc.text",                      "\uE66D"},  // draft / description
            {"xmark.bin",                     "\uE14C"},  // block (spam)
            {"archivebox",                    "\uE149"},  // archive
            {"trash",                         "\uE872"},  // delete
            {"pin",                           "\uF10D"},  // push_pin
            {"pin.fill",                      "\uF10D"},  // push_pin
            {"star",                          "\uE838"},  // star
            {"star.fill",                     "\uE838"},  // star
            {"info.circle",                   "\uE88E"},  // info
            {"banknote",                      "\uE227"},  // payments
            {"wrench.and.screwdriver",        "\uE8B8"},  // settings (closest)
            {"person.crop.circle.badge.plus", "\uE7FE"},  // person_add
            {"envelope.badge",                "\uE0BE"},  // mail
            // Toolbar icons
            {"magnifyingglass",               "\uE8B6"},  // search
            {"arrow.triangle.2.circlepath",   "\uE627"},  // sync
            {"square.and.pencil",             "\uE150"},  // create / compose
        };

        auto it = map.find(sfSymbol);
        if (it != map.end()) return *it;

        // Fallback: generic label icon
        return "\uE892";  // label
    }
};
