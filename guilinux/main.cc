#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include "models/ThreadModel.h"

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("Durian");

    QQuickStyle::setStyle("Basic");

    qmlRegisterType<ThreadModel>("Durian", 1, 0, "ThreadModel");

    QQmlApplicationEngine engine;
    engine.load(QUrl("qrc:/qml/Main.qml"));

    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
