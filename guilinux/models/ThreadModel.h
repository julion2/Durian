#pragma once

#include <QAbstractListModel>
#include <QString>
#include <QVector>
#include "data/SeedData.h"

class ThreadModel : public QAbstractListModel {
    Q_OBJECT

public:
    enum Role {
        SubjectRole = Qt::UserRole + 1,
        SenderRole,
        PreviewRole,
        InitialRole,
    };
    Q_ENUM(Role)

    explicit ThreadModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    QHash<int, QByteArray> roleNames() const override {
        return {
            {SubjectRole, "subject"},
            {SenderRole, "sender"},
            {PreviewRole, "preview"},
            {InitialRole, "initial"},
        };
    }

    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override {
        if (index.row() < 0 || index.row() >= threads_.size())
            return {};
        const auto &t = threads_[index.row()];
        switch (role) {
        case SubjectRole: return t.subject.isEmpty() ? "(No Subject)" : t.subject;
        case SenderRole: return t.sender;
        case PreviewRole: return t.preview;
        case InitialRole: return initialForSender(t.sender);
        default: return {};
        }
    }

    int rowCount(const QModelIndex &parent = QModelIndex()) const override {
        Q_UNUSED(parent);
        return threads_.size();
    }

    Q_INVOKABLE void loadSeedData() {
        beginResetModel();
        threads_ = seedThreads();
        endResetModel();
    }

    Q_INVOKABLE QString subject(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].subject.isEmpty() ? "(No Subject)" : threads_[row].subject;
    }

    Q_INVOKABLE QString sender(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].sender;
    }

    Q_INVOKABLE QString preview(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].preview;
    }

private:
    QVector<ThreadPreview> threads_;

    static QString initialForSender(const QString &sender) {
        for (const QChar &ch : sender) {
            if (ch.isLetterOrNumber()) return QString(ch).toUpper();
        }
        return "?";
    }
};

