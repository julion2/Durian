#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#include "models/ThreadModel.h"
#include "models/ProfileModel.h"
#include "models/NetworkClient.h"
#include "models/AvatarProvider.h"

int main(int argc, char *argv[]) {
    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    app.setApplicationName("Durian");

    QQuickStyle::setStyle("Basic");

    qmlRegisterType<ThreadModel>("Durian", 1, 0, "ThreadModel");
    qmlRegisterType<ProfileModel>("Durian", 1, 0, "ProfileModel");
    qmlRegisterType<NetworkClient>("Durian", 1, 0, "NetworkClient");

    QQmlApplicationEngine engine;
    engine.addImageProvider("avatar", new AvatarProvider());
    engine.load(QUrl("qrc:/qml/Main.qml"));

    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
