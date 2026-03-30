#pragma once

#include <QCryptographicHash>
#include <QDebug>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QSet>
#include <QThreadPool>
#include <QUrl>

// Personal email domains → Gravatar, everything else → Brandfetch
static const QSet<QString> kPersonalDomains = {
    "gmail.com", "googlemail.com",
    "outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.de",
    "yahoo.com", "yahoo.de", "ymail.com",
    "gmx.de", "gmx.net", "gmx.at", "gmx.ch",
    "web.de", "t-online.de", "freenet.de", "mail.de", "email.de",
    "icloud.com", "me.com", "mac.com",
    "aol.com",
    "protonmail.com", "proton.me", "pm.me",
    "posteo.de", "mailbox.org",
    "tutanota.com", "tutanota.de", "tuta.io",
    "stanford.edu",
};

class AvatarResponse : public QQuickImageResponse {
    Q_OBJECT

public:
    AvatarResponse(const QString &email, const QSize &size)
        : size_(size.isValid() ? size : QSize(128, 128))
    {
        auto *nam = new QNetworkAccessManager(this);
        QString decoded = QUrl::fromPercentEncoding(email.toUtf8());
        QString clean = extractEmail(decoded).toLower().trimmed();
        qDebug() << "AVATAR request:" << email << "-> decoded:" << decoded << "-> email:" << clean;
        if (clean.isEmpty()) { qDebug() << "AVATAR no email, skip"; emit finished(); return; }

        QString domain = clean.mid(clean.indexOf('@') + 1);
        QUrl url;

        if (kPersonalDomains.contains(domain)) {
            // Gravatar
            QByteArray hash = QCryptographicHash::hash(
                clean.toUtf8(), QCryptographicHash::Md5).toHex();
            url = QUrl(QString("https://gravatar.com/avatar/%1?d=404&s=%2")
                .arg(QString::fromLatin1(hash)).arg(size_.width()));
        } else {
            // Brandfetch
            url = QUrl(QString("https://cdn.brandfetch.io/%1?c=1idWonATCJFIseiVHIH").arg(domain));
        }

        QNetworkRequest req(url);
        if (!kPersonalDomains.contains(domain)) {
            req.setRawHeader("User-Agent",
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
        }

        qDebug() << "AVATAR fetching:" << url.toString();
        auto *reply = nam->get(req);
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            reply->deleteLater();
            if (reply->error() == QNetworkReply::NoError) {
                QByteArray data = reply->readAll();
                qDebug() << "AVATAR got" << data.size() << "bytes from" << reply->url().toString();
                if (!data.isEmpty()) {
                    QImage raw;
                    raw.loadFromData(data);
                    if (!raw.isNull()) {
                        // Scale and apply circular mask
                        int s = size_.width();
                        QImage scaled = raw.scaled(s, s, Qt::KeepAspectRatioByExpanding, Qt::SmoothTransformation);
                        // Center crop
                        int x = (scaled.width() - s) / 2;
                        int y = (scaled.height() - s) / 2;
                        scaled = scaled.copy(x, y, s, s);
                        // Circular mask
                        image_ = QImage(s, s, QImage::Format_ARGB32_Premultiplied);
                        image_.fill(Qt::transparent);
                        QPainter painter(&image_);
                        painter.setRenderHint(QPainter::Antialiasing);
                        QPainterPath path;
                        path.addEllipse(0, 0, s, s);
                        painter.setClipPath(path);
                        painter.drawImage(0, 0, scaled);
                    }
                }
            } else {
                qDebug() << "AVATAR error:" << reply->error() << reply->url().toString();
            }
            emit finished();
        });
    }

    QQuickTextureFactory *textureFactory() const override {
        if (image_.isNull()) return nullptr;
        return QQuickTextureFactory::textureFactoryForImage(image_);
    }

private:
    static QString extractEmail(const QString &from) {
        int lt = from.indexOf('<'), gt = from.indexOf('>');
        if (lt >= 0 && gt > lt)
            return from.mid(lt + 1, gt - lt - 1).trimmed();
        if (from.contains('@'))
            return from.trimmed();
        return {};
    }

    QImage image_;
    QSize size_;
};

class AvatarProvider : public QQuickAsyncImageProvider {
public:
    QQuickImageResponse *requestImageResponse(
        const QString &id, const QSize &requestedSize) override
    {
        return new AvatarResponse(id, requestedSize);
    }
};
