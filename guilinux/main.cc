#include <QApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMainWindow>
#include <QSplitter>
#include <QVBoxLayout>
#include <QWidget>

struct ThreadPreview {
    QString subject;
    QString sender;
    QString preview;
};

class MainWindow : public QMainWindow {
public:
    MainWindow() {
        setWindowTitle("Durian (Linux Spike)");
        resize(1100, 700);

        auto *root = new QWidget();
        auto *splitter = new QSplitter(Qt::Horizontal, root);

        auto *sidebar = new QWidget();
        auto *sidebarLayout = new QVBoxLayout(sidebar);
        sidebarLayout->setContentsMargins(12, 12, 12, 12);
        sidebarLayout->setSpacing(8);

        auto *sidebarTitle = new QLabel("Inbox");
        QFont titleFont = sidebarTitle->font();
        titleFont.setPointSize(16);
        titleFont.setBold(true);
        sidebarTitle->setFont(titleFont);
        sidebarLayout->addWidget(sidebarTitle);

        list_ = new QListWidget();
        sidebarLayout->addWidget(list_, 1);

        auto *detail = new QWidget();
        auto *detailLayout = new QVBoxLayout(detail);
        detailLayout->setContentsMargins(16, 16, 16, 16);
        detailLayout->setSpacing(10);

        subject_ = new QLabel("Select a thread");
        QFont subjectFont = subject_->font();
        subjectFont.setPointSize(18);
        subjectFont.setBold(true);
        subject_->setFont(subjectFont);

        meta_ = new QLabel("—");
        meta_->setStyleSheet("color: #666;");

        preview_ = new QLabel("—");
        preview_->setWordWrap(true);

        detailLayout->addWidget(subject_);
        detailLayout->addWidget(meta_);
        detailLayout->addWidget(preview_, 1);

        splitter->addWidget(sidebar);
        splitter->addWidget(detail);
        splitter->setStretchFactor(0, 1);
        splitter->setStretchFactor(1, 3);

        auto *rootLayout = new QHBoxLayout(root);
        rootLayout->setContentsMargins(0, 0, 0, 0);
        rootLayout->addWidget(splitter);
        setCentralWidget(root);

        seedData();
        connect(list_, &QListWidget::currentRowChanged, this, [this](int row) {
            if (row < 0 || row >= previews_.size()) {
                subject_->setText("Select a thread");
                meta_->setText("—");
                preview_->setText("—");
                return;
            }
            const auto &item = previews_[row];
            subject_->setText(item.subject);
            meta_->setText(item.sender);
            preview_->setText(item.preview);
        });
    }

private:
    void seedData() {
        previews_ = {
            {"Welcome to Durian", "julian@company.com", "This is a Linux GUI spike. Sidebar and detail view only."},
            {"Weekly report", "team@company.com", "Highlights from the week, action items, and open questions."},
            {"Design review", "design@company.com", "Agenda: navigation, message list, and detail view layout."},
        };
        for (const auto &item : previews_) {
            list_->addItem(item.subject + " — " + item.sender);
        }
        list_->setCurrentRow(0);
    }

    QListWidget *list_ = nullptr;
    QLabel *subject_ = nullptr;
    QLabel *meta_ = nullptr;
    QLabel *preview_ = nullptr;
    QVector<ThreadPreview> previews_;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    MainWindow window;
    window.show();
    return app.exec();
}
