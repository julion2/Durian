#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <QUrlQuery>

class NetworkClient : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString baseUrl READ baseUrl WRITE setBaseUrl NOTIFY baseUrlChanged)

public:
    explicit NetworkClient(QObject *parent = nullptr)
        : QObject(parent), manager_(new QNetworkAccessManager(this)) {}

    QString baseUrl() const { return baseUrl_; }
    void setBaseUrl(const QString &url) {
        if (baseUrl_ != url) {
            baseUrl_ = url;
            emit baseUrlChanged();
        }
    }

    Q_INVOKABLE void search(const QString &query, int limit = 50) {
        QUrl url(baseUrl_ + "/api/v1/search");
        QUrlQuery params;
        params.addQueryItem("query", query);
        params.addQueryItem("limit", QString::number(limit));
        params.addQueryItem("enrich", QString::number(limit));
        url.setQuery(params);

        auto *reply = manager_->get(QNetworkRequest(url));
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            reply->deleteLater();
            if (reply->error() != QNetworkReply::NoError) {
                emit searchError(reply->errorString());
                return;
            }
            auto doc = QJsonDocument::fromJson(reply->readAll());
            auto obj = doc.object();
            if (!obj.value("ok").toBool()) {
                emit searchError("API returned error");
                return;
            }
            // Merge preview text from enriched threads into results
            auto results = obj.value("results").toArray();
            auto threads = obj.value("threads").toObject();
            QJsonArray enriched;
            for (const auto &val : results) {
                auto r = val.toObject();
                auto tid = r.value("thread_id").toString();
                if (threads.contains(tid)) {
                    auto msgs = threads.value(tid).toObject()
                                    .value("messages").toArray();
                    if (!msgs.isEmpty()) {
                        auto body = msgs.first().toObject().value("body").toString();
                        // Trim to first 200 chars, collapse whitespace
                        body = body.left(200).simplified();
                        r.insert("preview", body);
                    }
                }
                enriched.append(r);
            }
            emit searchResults(enriched);
        });
    }

signals:
    void baseUrlChanged();
    void searchResults(const QJsonArray &results);
    void searchError(const QString &error);

private:
    QNetworkAccessManager *manager_;
    QString baseUrl_ = "http://localhost:9723";
};
