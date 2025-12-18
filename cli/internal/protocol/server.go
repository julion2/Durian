package protocol

import (
	"bufio"
	"encoding/json"
	"io"
)

// CommandHandler defines the interface for processing commands
type CommandHandler interface {
	Handle(cmd Command) Response
}

// Server handles JSON communication over reader/writer (typically stdin/stdout)
type Server struct {
	handler CommandHandler
	reader  io.Reader
	writer  io.Writer
}

// NewServer creates a new Server with the given handler and IO
func NewServer(handler CommandHandler, r io.Reader, w io.Writer) *Server {
	return &Server{
		handler: handler,
		reader:  r,
		writer:  w,
	}
}

// Run starts the JSON read loop, processing commands until EOF
func (s *Server) Run() {
	scanner := bufio.NewScanner(s.reader)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	encoder := json.NewEncoder(s.writer)

	for scanner.Scan() {
		var cmd Command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			encoder.Encode(FailWithMessage(ErrInvalidJSON, "invalid json: "+err.Error()))
			continue
		}

		resp := s.handler.Handle(cmd)
		encoder.Encode(resp)
	}
}
