package notmuch

// Compile-time interface checks
var (
	_ Client = (*MockClient)(nil)
	_ Client = (*ExecClient)(nil)
)

// MockClient implements Client interface for testing.
type MockClient struct {
	// Search/display results
	SearchResults  []SearchResult
	SearchErr      error
	Files          []string
	FilesErr       error
	TagErr         error
	ThreadMessages []ThreadMessage
	ThreadErr      error

	// Tag listing results
	Tags    []string
	TagsErr error

	// Sync results
	MessageExistsResult  bool
	FilenamesByMessageID []string
	DeleteFilesErr       error
	ModifyTagsErr        error
	AllMessagesWithTags  map[string][]string
	AllMessagesErr       error
	RunNewErr            error

	// Call tracking
	SearchCalls     []searchCall
	GetFilesCalls   []getFilesCall
	TagCalls        []tagCall
	ShowThreadCalls []showThreadCall
	ModifyTagsCalls []modifyTagsCall
}

type searchCall struct {
	Query string
	Limit int
}

type getFilesCall struct {
	Query string
	Limit int
}

type tagCall struct {
	Query string
	Tags  []string
}

type showThreadCall struct {
	ThreadID string
}

type modifyTagsCall struct {
	Query      string
	AddTags    []string
	RemoveTags []string
}

// NewMockClient creates a new MockClient with default empty values.
func NewMockClient() *MockClient {
	return &MockClient{
		SearchResults:       []SearchResult{},
		Files:               []string{},
		ThreadMessages:      []ThreadMessage{},
		AllMessagesWithTags: make(map[string][]string),
	}
}

func (m *MockClient) Search(query string, limit int) ([]SearchResult, error) {
	m.SearchCalls = append(m.SearchCalls, searchCall{Query: query, Limit: limit})
	if m.SearchErr != nil {
		return nil, m.SearchErr
	}
	return m.SearchResults, nil
}

func (m *MockClient) GetFiles(query string, limit int) ([]string, error) {
	m.GetFilesCalls = append(m.GetFilesCalls, getFilesCall{Query: query, Limit: limit})
	if m.FilesErr != nil {
		return nil, m.FilesErr
	}
	return m.Files, nil
}

func (m *MockClient) Tag(query string, tags []string) error {
	m.TagCalls = append(m.TagCalls, tagCall{Query: query, Tags: tags})
	return m.TagErr
}

func (m *MockClient) ShowThread(threadID string) ([]ThreadMessage, error) {
	m.ShowThreadCalls = append(m.ShowThreadCalls, showThreadCall{ThreadID: threadID})
	if m.ThreadErr != nil {
		return nil, m.ThreadErr
	}
	return m.ThreadMessages, nil
}

func (m *MockClient) ListTags() ([]string, error) {
	return m.Tags, m.TagsErr
}

func (m *MockClient) MessageExists(_ string) bool {
	return m.MessageExistsResult
}

func (m *MockClient) GetFilenamesByMessageID(_ string) []string {
	return m.FilenamesByMessageID
}

func (m *MockClient) DeleteMessageFiles(_ string) error {
	return m.DeleteFilesErr
}

func (m *MockClient) ModifyTags(query string, addTags []string, removeTags []string) error {
	m.ModifyTagsCalls = append(m.ModifyTagsCalls, modifyTagsCall{Query: query, AddTags: addTags, RemoveTags: removeTags})
	return m.ModifyTagsErr
}

func (m *MockClient) GetAllMessagesWithTags(_ string) (map[string][]string, error) {
	if m.AllMessagesErr != nil {
		return nil, m.AllMessagesErr
	}
	return m.AllMessagesWithTags, nil
}

func (m *MockClient) RunNew() error {
	return m.RunNewErr
}

// Reset clears all recorded calls.
func (m *MockClient) Reset() {
	m.SearchCalls = nil
	m.GetFilesCalls = nil
	m.TagCalls = nil
	m.ShowThreadCalls = nil
	m.ModifyTagsCalls = nil
}

// Builder pattern methods for chaining

func (m *MockClient) WithSearchResults(results []SearchResult) *MockClient {
	m.SearchResults = results
	return m
}

func (m *MockClient) WithSearchError(err error) *MockClient {
	m.SearchErr = err
	return m
}

func (m *MockClient) WithFiles(files []string) *MockClient {
	m.Files = files
	return m
}

func (m *MockClient) WithFilesError(err error) *MockClient {
	m.FilesErr = err
	return m
}

func (m *MockClient) WithTagError(err error) *MockClient {
	m.TagErr = err
	return m
}

func (m *MockClient) WithThreadMessages(messages []ThreadMessage) *MockClient {
	m.ThreadMessages = messages
	return m
}

func (m *MockClient) WithThreadError(err error) *MockClient {
	m.ThreadErr = err
	return m
}
