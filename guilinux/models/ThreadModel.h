#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QVector>
#include "data/SeedData.h"

class ThreadModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
    enum Role {
        SubjectRole = Qt::UserRole + 1,
        SenderRole,
        PreviewRole,
        InitialRole,
        DateRole,
        TagsRole,
        ThreadIdRole,
    };
    Q_ENUM(Role)

    explicit ThreadModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    QHash<int, QByteArray> roleNames() const override {
        return {
            {SubjectRole, "subject"},
            {SenderRole, "sender"},
            {PreviewRole, "preview"},
            {InitialRole, "initial"},
            {DateRole, "date"},
            {TagsRole, "tags"},
            {ThreadIdRole, "threadId"},
        };
    }

    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override {
        if (index.row() < 0 || index.row() >= threads_.size())
            return {};
        const auto &t = threads_[index.row()];
        switch (role) {
        case SubjectRole: return t.subject.isEmpty() ? "(No Subject)" : t.subject;
        case SenderRole: return displayName(t.sender);
        case PreviewRole: return t.preview;
        case InitialRole: return initialForSender(t.sender);
        case DateRole: return t.date;
        case TagsRole: return t.tags;
        case ThreadIdRole: return t.threadId;
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
        return displayName(threads_[row].sender);
    }

    Q_INVOKABLE QString preview(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].preview;
    }

    Q_INVOKABLE QString date(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].date;
    }

    Q_INVOKABLE QString threadId(int row) const {
        if (row < 0 || row >= threads_.size()) return {};
        return threads_[row].threadId;
    }

public slots:
    void loadFromJson(const QJsonArray &results) {
        beginResetModel();
        threads_.clear();
        for (const auto &val : results) {
            auto obj = val.toObject();
            ThreadPreview t;
            t.threadId = obj.value("thread_id").toString();
            t.subject = obj.value("subject").toString();
            t.sender = obj.value("from").toString();
            t.preview = obj.value("preview").toString();
            t.date = obj.value("date").toString();
            t.tags = obj.value("tags").toString();
            threads_.append(t);
        }
        endResetModel();
        emit countChanged();
    }

signals:
    void countChanged();

private:
    QVector<ThreadPreview> threads_;

    // "Display Name <email>" → "Display Name", or email if no name
    static QString displayName(const QString &from) {
        int lt = from.indexOf('<');
        if (lt > 0) {
            QString name = from.left(lt).trimmed();
            // Strip surrounding quotes
            if (name.startsWith('"') && name.endsWith('"'))
                name = name.mid(1, name.length() - 2);
            if (!name.isEmpty()) return name;
        }
        // No angle brackets — might just be an email
        return from.trimmed();
    }

    static QString initialForSender(const QString &sender) {
        QString name = displayName(sender);
        for (const QChar &ch : name) {
            if (ch.isLetterOrNumber()) return QString(ch).toUpper();
        }
        return "?";
    }
};

