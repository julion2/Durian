package notmuch

// MockClient implements Client interface for testing
type MockClient struct {
	// SearchResults is returned by Search()
	SearchResults []SearchResult
	// SearchErr is returned as error by Search()
	SearchErr error

	// Files is returned by GetFiles()
	Files []string
	// FilesErr is returned as error by GetFiles()
	FilesErr error

	// TagErr is returned as error by Tag()
	TagErr error

	// ThreadMessages is returned by ShowThread()
	ThreadMessages []ThreadMessage
	// ThreadErr is returned as error by ShowThread()
	ThreadErr error

	// Track calls for verification
	SearchCalls     []searchCall
	GetFilesCalls   []getFilesCall
	TagCalls        []tagCall
	ShowThreadCalls []showThreadCall
}

type showThreadCall struct {
	ThreadID string
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

// NewMockClient creates a new MockClient with default empty values
func NewMockClient() *MockClient {
	return &MockClient{
		SearchResults:  []SearchResult{},
		Files:          []string{},
		ThreadMessages: []ThreadMessage{},
	}
}

// Search returns the configured SearchResults and SearchErr
func (m *MockClient) Search(query string, limit int) ([]SearchResult, error) {
	m.SearchCalls = append(m.SearchCalls, searchCall{Query: query, Limit: limit})

	if m.SearchErr != nil {
		return nil, m.SearchErr
	}
	return m.SearchResults, nil
}

// GetFiles returns the configured Files and FilesErr
func (m *MockClient) GetFiles(query string, limit int) ([]string, error) {
	m.GetFilesCalls = append(m.GetFilesCalls, getFilesCall{Query: query, Limit: limit})

	if m.FilesErr != nil {
		return nil, m.FilesErr
	}
	return m.Files, nil
}

// Tag returns the configured TagErr
func (m *MockClient) Tag(query string, tags []string) error {
	m.TagCalls = append(m.TagCalls, tagCall{Query: query, Tags: tags})

	return m.TagErr
}

// ShowThread returns the configured ThreadMessages and ThreadErr
func (m *MockClient) ShowThread(threadID string) ([]ThreadMessage, error) {
	m.ShowThreadCalls = append(m.ShowThreadCalls, showThreadCall{ThreadID: threadID})

	if m.ThreadErr != nil {
		return nil, m.ThreadErr
	}
	return m.ThreadMessages, nil
}

// Reset clears all recorded calls
func (m *MockClient) Reset() {
	m.SearchCalls = nil
	m.GetFilesCalls = nil
	m.TagCalls = nil
	m.ShowThreadCalls = nil
}

// WithSearchResults sets SearchResults and returns the mock for chaining
func (m *MockClient) WithSearchResults(results []SearchResult) *MockClient {
	m.SearchResults = results
	return m
}

// WithSearchError sets SearchErr and returns the mock for chaining
func (m *MockClient) WithSearchError(err error) *MockClient {
	m.SearchErr = err
	return m
}

// WithFiles sets Files and returns the mock for chaining
func (m *MockClient) WithFiles(files []string) *MockClient {
	m.Files = files
	return m
}

// WithFilesError sets FilesErr and returns the mock for chaining
func (m *MockClient) WithFilesError(err error) *MockClient {
	m.FilesErr = err
	return m
}

// WithTagError sets TagErr and returns the mock for chaining
func (m *MockClient) WithTagError(err error) *MockClient {
	m.TagErr = err
	return m
}

// WithThreadMessages sets ThreadMessages and returns the mock for chaining
func (m *MockClient) WithThreadMessages(messages []ThreadMessage) *MockClient {
	m.ThreadMessages = messages
	return m
}

// WithThreadError sets ThreadErr and returns the mock for chaining
func (m *MockClient) WithThreadError(err error) *MockClient {
	m.ThreadErr = err
	return m
}
