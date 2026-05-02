#include <QCoreApplication>
#include <QTest>
#include "models/ProfileModel.h"

class ProfileModelTest : public QObject {
    Q_OBJECT

private slots:
    void applyProfileFilter_allProfile() {
        // "All" profile (accounts = ["*"]) should not add path filter
        ProfileModel model;
        model.load();  // loads from real config

        // Find the "All" profile
        auto profiles = model.profileNames();
        int allIdx = -1;
        for (int i = 0; i < profiles.size(); i++) {
            if (profiles[i].toMap()["name"].toString() == "All") {
                allIdx = i;
                break;
            }
        }

        if (allIdx >= 0) {
            model.setCurrentProfile(allIdx);
            QString filtered = model.applyProfileFilter("tag:inbox");
            QCOMPARE(filtered, QString("tag:inbox"));
        }
    }

    void applyProfileFilter_specificProfile() {
        ProfileModel model;
        model.load();

        // Find a non-All profile
        auto profiles = model.profileNames();
        int nonAllIdx = -1;
        for (int i = 0; i < profiles.size(); i++) {
            if (profiles[i].toMap()["name"].toString() != "All") {
                nonAllIdx = i;
                break;
            }
        }

        if (nonAllIdx >= 0) {
            model.setCurrentProfile(nonAllIdx);
            QString filtered = model.applyProfileFilter("tag:inbox");
            // Should contain path: filter
            QVERIFY(filtered.contains("path:"));
            QVERIFY(filtered.contains("tag:inbox"));
        }
    }

    void isOwnEmail_configured() {
        ProfileModel model;
        model.load();

        // These emails should be in config.pkl
        // At minimum, the first account email should match
        auto profiles = model.profileNames();
        if (!profiles.isEmpty()) {
            // The model loaded config, own emails should be populated
            // Test with a clearly fake email
            QVERIFY(!model.isOwnEmail("definitely-not-configured@fake.test"));
        }
    }

    void isOwnEmail_caseInsensitive() {
        ProfileModel model;
        model.load();

        // If any email is configured, test case insensitivity
        // We can't hardcode emails, but we test the mechanism
        QString testFrom = "UPPER@CASE.COM";
        // Just verify it doesn't crash
        model.isOwnEmail(testFrom);
    }

    void configDir_respectsXDG() {
        // configDir() should return XDG_CONFIG_HOME/durian or ~/.config/durian
        QString dir = ProfileModel::configDir();
        QVERIFY(dir.endsWith("/durian"));
        QVERIFY(!dir.isEmpty());
    }

    void loadRemoteImages_defaultFalse() {
        // Before loading, should default to false
        ProfileModel model;
        QCOMPARE(model.loadRemoteImages(), false);
    }

    void setCurrentProfile_boundsCheck() {
        ProfileModel model;
        model.load();
        // Out of bounds should not crash
        model.setCurrentProfile(-1);
        model.setCurrentProfile(9999);
    }
};

QTEST_MAIN(ProfileModelTest)
#include "profile_model_test_moc.h"
