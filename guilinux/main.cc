#include <QApplication>
#include <QDateTime>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMainWindow>
#include <QSplitter>
#include <QToolButton>
#include <QTextEdit>
#include <QVBoxLayout>
#include <QWidget>

struct ThreadPreview {
    QString subject;
    QString sender;
    QString preview;
};

static QString initialForSender(const QString &sender) {
    for (const QChar &ch : sender) {
        if (ch.isLetterOrNumber()) {
            return QString(ch).toUpper();
        }
    }
    return "?";
}

static QWidget *buildThreadRow(const ThreadPreview &thread) {
    auto *row = new QFrame();
    row->setObjectName("threadRow");
    row->setProperty("selected", false);

    auto *layout = new QHBoxLayout(row);
    layout->setContentsMargins(10, 8, 10, 8);
    layout->setSpacing(10);

    auto *avatar = new QLabel(initialForSender(thread.sender));
    avatar->setFixedSize(32, 32);
    avatar->setAlignment(Qt::AlignCenter);
    avatar->setObjectName("avatar");

    auto *textCol = new QVBoxLayout();
    textCol->setSpacing(4);

    auto *sender = new QLabel(thread.sender);
    sender->setObjectName("sender");
    sender->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);

    auto *subject = new QLabel(thread.subject.isEmpty() ? "(No Subject)" : thread.subject);
    subject->setObjectName("subject");
    subject->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);

    auto *preview = new QLabel(thread.preview);
    preview->setObjectName("preview");
    preview->setWordWrap(true);

    textCol->addWidget(sender);
    textCol->addWidget(subject);
    textCol->addWidget(preview);

    layout->addWidget(avatar);
    layout->addLayout(textCol, 1);

    row->setStyleSheet(
        "#threadRow { background: #ffffff; border: 1px solid #e6e6e6; border-radius: 8px; }"
        "#threadRow[selected=\"true\"] { background: #ede7f6; border: 1px solid #d8ccef; }"
        "#avatar { background: #f0f0f0; border-radius: 16px; color: #333; font-weight: 600; }"
        "#sender { font-size: 13px; font-weight: 600; color: #111; }"
        "#subject { font-size: 12px; font-weight: 500; color: #222; }"
        "#preview { font-size: 11px; color: #666; }"
    );

    return row;
}

class MainWindow : public QMainWindow {
public:
    MainWindow() {
        setWindowTitle("Durian");
        resize(1100, 720);

        auto *root = new QWidget();
        splitter_ = new QSplitter(Qt::Horizontal, root);

        sidebar_ = new QWidget();
        sidebarLayout_ = new QVBoxLayout(sidebar_);
        sidebarLayout_->setContentsMargins(10, 10, 10, 10);
        sidebarLayout_->setSpacing(8);
        sidebarLayout_->setAlignment(Qt::AlignTop);

        sidebarHeader_ = new QWidget();
        auto *sidebarHeaderLayout = new QHBoxLayout(sidebarHeader_);
        sidebarHeaderLayout->setContentsMargins(0, 0, 0, 0);
        sidebarHeaderLayout->setSpacing(8);

        auto *toggleButton = new QToolButton();
        toggleButton->setToolButtonStyle(Qt::ToolButtonTextOnly);
        toggleButton->setText("≡");
        QFont toggleFont = toggleButton->font();
        toggleFont.setPointSize(16);
        toggleFont.setBold(true);
        toggleButton->setFont(toggleFont);
        toggleButton->setAutoRaise(true);
        toggleButton->setFixedSize(24, 24);
        toggleButton->setStyleSheet(
            "QToolButton { border: none; background: transparent; padding: 0px; }"
            "QToolButton:hover { background: #f2f2f2; border-radius: 6px; }"
        );

        sidebarTitle_ = new QLabel("Mailboxes");
        QFont titleFont = sidebarTitle_->font();
        titleFont.setPointSize(13);
        titleFont.setBold(true);
        sidebarTitle_->setFont(titleFont);

        sidebarHeaderLayout->addWidget(toggleButton);
        sidebarHeaderLayout->addWidget(sidebarTitle_);
        sidebarHeaderLayout->addStretch(1);
        sidebarLayout_->addWidget(sidebarHeader_);

        sidebarList_ = new QListWidget();
        sidebarList_->setFrameShape(QFrame::NoFrame);
        sidebarList_->setSpacing(6);
        sidebarList_->setStyleSheet(
            "QListWidget { background: #ffffff; border: none; }"
            "QListWidget::item { padding: 6px 10px; color: #111; }"
            "QListWidget::item:selected { background: #ede7f6; border-radius: 6px; color: #111; }"
        );
        sidebarList_->addItem("Inbox");
        sidebarList_->addItem("Pinned");
        sidebarList_->addItem("Archive");
        sidebarList_->addItem("Sent");
        sidebarList_->addItem("Drafts");
        sidebarList_->addItem("Trash");
        sidebarList_->setCurrentRow(0);
        sidebarLayout_->addWidget(sidebarList_, 1);
        sidebarLayout_->addStretch(1);

        auto *listPane = new QWidget();
        auto *listLayout = new QVBoxLayout(listPane);
        listLayout->setContentsMargins(10, 10, 10, 10);
        listLayout->setSpacing(8);

        auto *listTitle = new QLabel("Inbox");
        QFont listTitleFont = listTitle->font();
        listTitleFont.setPointSize(15);
        listTitleFont.setBold(true);
        listTitle->setFont(listTitleFont);
        listLayout->addWidget(listTitle);

        list_ = new QListWidget();
        list_->setFrameShape(QFrame::NoFrame);
        list_->setSelectionMode(QAbstractItemView::SingleSelection);
        list_->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
        list_->setSpacing(6);
        list_->setStyleSheet(
            "QListWidget { background: #ffffff; border: none; }"
            "QListWidget::item { padding: 0px; }"
            "QListWidget::item:selected { background: #ede7f6; border-radius: 8px; }"
        );
        listLayout->addWidget(list_, 1);

        auto *detail = new QWidget();
        auto *detailLayout = new QVBoxLayout(detail);
        detailLayout->setContentsMargins(12, 12, 12, 12);
        detailLayout->setSpacing(8);

        subject_ = new QLabel("Select a thread");
        QFont subjectFont = subject_->font();
        subjectFont.setPointSize(18);
        subjectFont.setBold(true);
        subject_->setFont(subjectFont);

        meta_ = new QLabel("—");
        meta_->setStyleSheet("color: #666;");

        body_ = new QTextEdit();
        body_->setReadOnly(true);
        body_->setFrameShape(QFrame::NoFrame);
        body_->setStyleSheet(
            "QTextEdit { background: #ffffff; border: 1px solid #e6e6e6; border-radius: 10px; padding: 10px; }"
        );

        detailLayout->addWidget(subject_);
        detailLayout->addWidget(meta_);
        detailLayout->addWidget(body_, 1);

        splitter_->addWidget(sidebar_);
        splitter_->addWidget(listPane);
        splitter_->addWidget(detail);
        splitter_->setStretchFactor(0, 1);
        splitter_->setStretchFactor(1, 3);
        splitter_->setStretchFactor(2, 6);
        splitter_->setSizes({140, 360, 620});
        splitter_->setHandleWidth(1);
        splitter_->setStyleSheet("QSplitter::handle { background: #e6e6e6; }");

        auto *rootLayout = new QHBoxLayout(root);
        rootLayout->setContentsMargins(6, 6, 6, 6);
        rootLayout->addWidget(splitter_);
        setCentralWidget(root);

        seedData();
        connect(toggleButton, &QToolButton::clicked, this, [this]() {
            sidebarVisible_ = !sidebarVisible_;
            sidebarList_->setVisible(sidebarVisible_);
            sidebarTitle_->setVisible(sidebarVisible_);
            if (sidebarVisible_) {
                sidebar_->setMinimumWidth(120);
                sidebar_->setMaximumWidth(260);
                sidebarLayout_->setContentsMargins(10, 10, 10, 10);
                splitter_->setSizes({140, 360, 620});
            } else {
                sidebar_->setMinimumWidth(36);
                sidebar_->setMaximumWidth(36);
                sidebarLayout_->setContentsMargins(6, 10, 6, 10);
                splitter_->setSizes({36, 420, 700});
            }
        });
        connect(list_, &QListWidget::currentRowChanged, this, [this](int row) {
            updateRowSelection(row);
            if (row < 0 || row >= previews_.size()) {
                subject_->setText("Select a thread");
                meta_->setText("—");
                body_->setPlainText("—");
                return;
            }
            const auto &item = previews_[row];
            subject_->setText(item.subject.isEmpty() ? "(No Subject)" : item.subject);
            meta_->setText(item.sender + "  ·  " + QDateTime::currentDateTime().toString("MMM d, h:mm a"));
            body_->setPlainText(item.preview + "\n\nLorem ipsum placeholder body content.");
        });
    }

private:
    void seedData() {
        previews_ = {
            {"Welcome to Durian", "julian@company.com", "This is a Linux GUI spike with a sidebar and detail view."},
            {"Weekly report", "team@company.com", "Highlights from the week, action items, and open questions."},
            {"Design review", "design@company.com", "Agenda: navigation, message list, and detail view layout."},
        };

        for (const auto &item : previews_) {
            auto *listItem = new QListWidgetItem();
            listItem->setSizeHint(QSize(10, 84));
            list_->addItem(listItem);
            list_->setItemWidget(listItem, buildThreadRow(item));
        }
        list_->setCurrentRow(0);
    }

    void updateRowSelection(int selectedRow) {
        for (int i = 0; i < list_->count(); ++i) {
            auto *item = list_->item(i);
            if (!item) {
                continue;
            }
            auto *widget = list_->itemWidget(item);
            if (!widget) {
                continue;
            }
            widget->setProperty("selected", i == selectedRow);
            widget->style()->unpolish(widget);
            widget->style()->polish(widget);
            widget->update();
        }
    }

    QListWidget *list_ = nullptr;
    QLabel *subject_ = nullptr;
    QLabel *meta_ = nullptr;
    QTextEdit *body_ = nullptr;
    QVector<ThreadPreview> previews_;
    QSplitter *splitter_ = nullptr;
    QWidget *sidebar_ = nullptr;
    QWidget *sidebarHeader_ = nullptr;
    QListWidget *sidebarList_ = nullptr;
    QVBoxLayout *sidebarLayout_ = nullptr;
    QLabel *sidebarTitle_ = nullptr;
    bool sidebarVisible_ = true;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    MainWindow window;
    window.show();
    return app.exec();
}
