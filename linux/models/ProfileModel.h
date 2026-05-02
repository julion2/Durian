#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>

#include "models/IconMap.h"

struct FolderConfig {
    QString name;
    QString icon;    // SF Symbol name
    QString query;
};

struct Profile {
    QString name;
    QStringList accounts;
    bool isDefault = false;
    QString color;
    QVector<FolderConfig> folders;
};

class ProfileModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList profiles READ profileNames NOTIFY profilesChanged)
    Q_PROPERTY(int currentProfile READ currentProfile WRITE setCurrentProfile NOTIFY currentProfileChanged)
    Q_PROPERTY(QVariantList folders READ currentFolders NOTIFY currentProfileChanged)
    Q_PROPERTY(bool loadRemoteImages READ loadRemoteImages NOTIFY configLoaded)

public:
    explicit ProfileModel(QObject *parent = nullptr) : QObject(parent) {}

    bool loadRemoteImages() const { return loadRemoteImages_; }

    Q_INVOKABLE bool isOwnEmail(const QString &from) const {
        QString lower = from.toLower();
        for (const auto &email : ownEmails_) {
            if (lower.contains(email)) return true;
        }
        return false;
    }

    static QString configDir() {
        QString xdg = QProcessEnvironment::systemEnvironment().value("XDG_CONFIG_HOME");
        if (xdg.isEmpty())
            xdg = QDir::homePath() + "/.config";
        return xdg + "/durian";
    }

    // Locate the schema directory (Profiles.pkl, Config.pkl, ...).
    // Order:
    //   1. $DURIAN_SCHEMA_DIR
    //   2. <binary dir>/../schema  (Bazel runfiles layout)
    //   3. <binary dir>/schema
    //   4. /usr/local/share/durian/schema
    //   5. /usr/share/durian/schema
    static QString schemaDir() {
        auto envVal = [](const char *name) -> QString {
            return QProcessEnvironment::systemEnvironment().value(name);
        };

        QString env = envVal("DURIAN_SCHEMA_DIR");
        if (!env.isEmpty() && QFileInfo(env + "/Profiles.pkl").exists())
            return env;

        // Bazel runfiles: $RUNFILES_DIR/_main/schema or <binary>.runfiles/_main/schema
        QString runfiles = envVal("RUNFILES_DIR");
        if (runfiles.isEmpty()) {
            QString self = QCoreApplication::applicationFilePath();
            if (!self.isEmpty()) runfiles = self + ".runfiles";
        }

        QString appDir = QCoreApplication::applicationDirPath();
        for (const QString &candidate : {
                 runfiles + "/_main/schema",
                 appDir + "/../schema",
                 appDir + "/schema",
                 QStringLiteral("/usr/local/share/durian/schema"),
                 QStringLiteral("/usr/share/durian/schema"),
             }) {
            if (QFileInfo(candidate + "/Profiles.pkl").exists())
                return QDir(candidate).absolutePath();
        }
        return {};
    }

    Q_INVOKABLE void load() {
        profiles_.clear();
        ownEmails_.clear();
        loadConfig();
        loadProfiles();

        // Find default profile
        currentProfile_ = 0;
        for (int i = 0; i < profiles_.size(); ++i) {
            if (profiles_[i].isDefault) {
                currentProfile_ = i;
                break;
            }
        }

        emit profilesChanged();
        emit currentProfileChanged();
    }

    QVariantList profileNames() const {
        QVariantList list;
        for (const auto &p : profiles_) {
            QVariantMap m;
            m["name"] = p.name;
            m["color"] = p.color;
            list.append(m);
        }
        return list;
    }

    int currentProfile() const { return currentProfile_; }
    void setCurrentProfile(int idx) {
        if (idx >= 0 && idx < profiles_.size() && idx != currentProfile_) {
            currentProfile_ = idx;
            emit currentProfileChanged();
        }
    }

    QVariantList currentFolders() const {
        QVariantList list;
        if (currentProfile_ < 0 || currentProfile_ >= profiles_.size())
            return list;
        for (const auto &f : profiles_[currentProfile_].folders) {
            QVariantMap m;
            m["name"] = f.name;
            m["icon"] = IconMap::toMaterialSymbol(f.icon);
            m["query"] = f.query;
            list.append(m);
        }
        return list;
    }

    Q_INVOKABLE QString folderQuery(int idx) const {
        if (currentProfile_ < 0 || currentProfile_ >= profiles_.size())
            return {};
        const auto &folders = profiles_[currentProfile_].folders;
        if (idx < 0 || idx >= folders.size())
            return {};
        return applyProfileFilter(folders[idx].query);
    }

    Q_INVOKABLE QString applyProfileFilter(const QString &baseQuery) const {
        if (currentProfile_ < 0 || currentProfile_ >= profiles_.size())
            return baseQuery;
        const auto &p = profiles_[currentProfile_];
        // "All" profile (accounts = ["*"]) → no filter
        if (p.accounts.contains("*") || p.accounts.isEmpty())
            return baseQuery;
        // Build path filter: (path:work/** OR path:personal/**)
        QStringList pathFilters;
        for (const auto &acc : p.accounts)
            pathFilters.append("path:" + acc + "/**");
        return "(" + baseQuery + ") AND (" + pathFilters.join(" OR ") + ")";
    }

signals:
    void profilesChanged();
    void currentProfileChanged();
    void configLoaded();

private:
    // Run `pkl eval --format json [--module-path <schemaDir>] <file>` and
    // return the JSON document. Returns a null document on failure.
    static QJsonDocument pklEval(const QString &pklFile) {
        if (!QFileInfo(pklFile).exists())
            return {};

        QStringList args = {"eval", "--format", "json"};
        QString sd = schemaDir();
        if (!sd.isEmpty()) {
            // pkl rejects --module-path entries that contain symlinks; resolve
            // to the canonical path so Bazel runfiles trees work too.
            QString sdReal = QFileInfo(sd + "/Profiles.pkl").canonicalFilePath();
            if (!sdReal.isEmpty())
                sd = QFileInfo(sdReal).absolutePath();
            args << "--module-path" << sd
                 << "--allowed-modules" << "file:,modulepath:";
        }
        args << pklFile;

        // Resolve pkl absolute path (Bazel-run may strip PATH).
        QString pklBin = QStandardPaths::findExecutable("pkl");
        if (pklBin.isEmpty()) {
            for (const QString &c : {"/opt/homebrew/bin/pkl", "/usr/local/bin/pkl", "/usr/bin/pkl"}) {
                if (QFileInfo(c).isExecutable()) { pklBin = c; break; }
            }
        }
        if (pklBin.isEmpty()) pklBin = "pkl";

        QProcess proc;
        proc.start(pklBin, args);
        if (!proc.waitForFinished(10000) || proc.exitStatus() != QProcess::NormalExit ||
            proc.exitCode() != 0) {
            return {};
        }
        QByteArray out = proc.readAllStandardOutput();
        QJsonParseError err{};
        QJsonDocument doc = QJsonDocument::fromJson(out, &err);
        if (err.error != QJsonParseError::NoError)
            return {};
        return doc;
    }

    void loadProfiles() {
        QJsonDocument doc = pklEval(configDir() + "/profiles.pkl");
        if (!doc.isObject()) return;
        QJsonArray arr = doc.object().value("profiles").toArray();
        for (const QJsonValue &v : arr) {
            QJsonObject obj = v.toObject();
            Profile p;
            p.name = obj.value("name").toString();
            p.isDefault = obj.value("default").toBool();
            p.color = obj.value("color").toString();
            for (const QJsonValue &a : obj.value("accounts").toArray())
                p.accounts.append(a.toString());
            for (const QJsonValue &f : obj.value("folders").toArray()) {
                QJsonObject fobj = f.toObject();
                FolderConfig fc;
                fc.name = fobj.value("name").toString();
                fc.icon = fobj.value("icon").toString();
                fc.query = fobj.value("query").toString();
                p.folders.append(fc);
            }
            profiles_.append(p);
        }
    }

    void loadConfig() {
        QJsonDocument doc = pklEval(configDir() + "/config.pkl");
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            QJsonObject settings = root.value("settings").toObject();
            loadRemoteImages_ = settings.value("load_remote_images").toBool(false);
        }
        emit configLoaded();
    }

    QVector<Profile> profiles_;
    QStringList ownEmails_;
    bool loadRemoteImages_ = false;
    int currentProfile_ = 0;
};
