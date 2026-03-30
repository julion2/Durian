#pragma once

#include <QAbstractListModel>
#include <QDir>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QString>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>

#define TOML_HEADER_ONLY 1
#include "third_party/toml.hpp"

#include "models/IconMap.h"

struct FolderConfig {
    QString name;
    QString icon;    // SF Symbol name from TOML
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

    Q_INVOKABLE void load() {
        profiles_.clear();
        ownEmails_.clear();
        loadConfig();
        QString path = configDir() + "/profiles.toml";

        try {
            auto tbl = toml::parse_file(path.toStdString());
            if (auto arr = tbl.get_as<toml::array>("profile")) {
                for (auto &item : *arr) {
                    auto *ptbl = item.as_table();
                    if (!ptbl) continue;

                    Profile p;
                    if (auto n = ptbl->get_as<std::string>("name"))
                        p.name = QString::fromStdString(**n);
                    if (auto d = ptbl->get_as<bool>("default"))
                        p.isDefault = **d;
                    if (auto c = ptbl->get_as<std::string>("color"))
                        p.color = QString::fromStdString(**c);
                    if (auto accs = ptbl->get_as<toml::array>("accounts")) {
                        for (auto &a : *accs) {
                            if (auto s = a.as_string())
                                p.accounts.append(QString::fromStdString(**s));
                        }
                    }

                    if (auto folders = ptbl->get_as<toml::array>("folders")) {
                        for (auto &f : *folders) {
                            auto *ftbl = f.as_table();
                            if (!ftbl) continue;
                            FolderConfig fc;
                            if (auto n = ftbl->get_as<std::string>("name"))
                                fc.name = QString::fromStdString(**n);
                            if (auto i = ftbl->get_as<std::string>("icon"))
                                fc.icon = QString::fromStdString(**i);
                            if (auto q = ftbl->get_as<std::string>("query"))
                                fc.query = QString::fromStdString(**q);
                            p.folders.append(fc);
                        }
                    }

                    profiles_.append(p);
                }
            }
        } catch (...) {
            // Fallback: empty profiles
        }

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
    void loadConfig() {
        QString path = configDir() + "/config.toml";
        try {
            auto tbl = toml::parse_file(path.toStdString());
            if (auto accs = tbl.get_as<toml::array>("accounts")) {
                for (auto &item : *accs) {
                    auto *atbl = item.as_table();
                    if (!atbl) continue;
                    if (auto e = atbl->get_as<std::string>("email"))
                        ownEmails_.append(QString::fromStdString(**e).toLower());
                }
            }
            if (auto settings = tbl.get_as<toml::table>("settings")) {
                if (auto lri = settings->get_as<bool>("load_remote_images"))
                    loadRemoteImages_ = **lri;
            }
        } catch (...) {}
        emit configLoaded();
    }

    QVector<Profile> profiles_;
    QStringList ownEmails_;
    bool loadRemoteImages_ = false;
    int currentProfile_ = 0;
};
