#pragma once

#include <QVector>
#include <QString>

struct ThreadPreview {
    QString subject;
    QString sender;
    QString preview;
};

inline QVector<ThreadPreview> seedThreads() {
    return {
        {"Welcome to Durian", "julian@company.com",
         "This is a Linux GUI spike with a sidebar and detail view."},
        {"Weekly report", "team@company.com",
         "Highlights from the week, action items, and open questions."},
        {"Design review", "design@company.com",
         "Agenda: navigation, message list, and detail view layout."},
    };
}
