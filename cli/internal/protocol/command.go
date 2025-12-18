package protocol

// Command represents a JSON command received from the client (GUI or CLI)
type Command struct {
	Cmd    string `json:"cmd"`
	Query  string `json:"query,omitempty"`
	File   string `json:"file,omitempty"`
	Thread string `json:"thread,omitempty"`
	Tags   string `json:"tags,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}
