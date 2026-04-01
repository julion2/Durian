#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QTest>
#include "models/ThreadModel.h"

class ThreadModelTest : public QObject {
    Q_OBJECT

private slots:
    void displayName_withAngleBrackets() {
        QCOMPARE(ThreadModel::displayName("PMO <pmo@example.com>"), QString("PMO"));
    }

    void displayName_quotedName() {
        QCOMPARE(ThreadModel::displayName("\"Schenker, Julian\" <j@example.com>"), QString("Schenker, Julian"));
    }

    void displayName_emailOnly() {
        QCOMPARE(ThreadModel::displayName("<info@example.com>"), QString("info@example.com"));
    }

    void displayName_plainEmail() {
        QCOMPARE(ThreadModel::displayName("user@example.com"), QString("user@example.com"));
    }

    void displayName_empty() {
        QCOMPARE(ThreadModel::displayName(""), QString(""));
    }

    void initialForSender_normalName() {
        // initialForSender uses displayName internally, then extracts first letter
        QString initial = ThreadModel::initialForSender("Julian Schenker <j@example.com>");
        QCOMPARE(initial, QString("J"));
    }

    void initialForSender_emailOnly() {
        QString initial = ThreadModel::initialForSender("<info@example.com>");
        QCOMPARE(initial, QString("I"));
    }

    void initialForSender_empty() {
        QCOMPARE(ThreadModel::initialForSender(""), QString("?"));
    }

    void loadFromJson_populatesModel() {
        ThreadModel model;
        QJsonArray results;
        QJsonObject msg;
        msg["thread_id"] = "abc123";
        msg["subject"] = "Test Subject";
        msg["from"] = "Sender <sender@test.com>";
        msg["preview"] = "Preview text";
        msg["date"] = "12:30";
        msg["tags"] = "inbox,important";
        results.append(msg);

        model.loadFromJson(results);

        QCOMPARE(model.rowCount(), 1);
        QCOMPARE(model.subject(0), QString("Test Subject"));
        QCOMPARE(model.sender(0), QString("Sender"));
        QCOMPARE(model.preview(0), QString("Preview text"));
        QCOMPARE(model.threadId(0), QString("abc123"));
        QCOMPARE(model.date(0), QString("12:30"));
    }

    void loadFromJson_emptySubject() {
        ThreadModel model;
        QJsonArray results;
        QJsonObject msg;
        msg["thread_id"] = "x";
        msg["subject"] = "";
        msg["from"] = "Test <t@t.com>";
        results.append(msg);

        model.loadFromJson(results);
        QCOMPARE(model.subject(0), QString("(No Subject)"));
    }

    void loadFromJson_emptyResults() {
        ThreadModel model;
        model.loadFromJson(QJsonArray());
        QCOMPARE(model.rowCount(), 0);
    }

    void count_updatesAfterLoad() {
        ThreadModel model;
        QCOMPARE(model.property("count").toInt(), 0);

        QJsonArray results;
        QJsonObject msg;
        msg["thread_id"] = "1";
        msg["from"] = "A <a@b.com>";
        results.append(msg);
        results.append(msg);

        model.loadFromJson(results);
        QCOMPARE(model.property("count").toInt(), 2);
    }

    void outOfBoundsAccess() {
        ThreadModel model;
        QCOMPARE(model.subject(-1), QString());
        QCOMPARE(model.subject(0), QString());
        QCOMPARE(model.sender(99), QString());
    }
};

QTEST_MAIN(ThreadModelTest)
#include "thread_model_test_moc.h"
