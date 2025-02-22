package health

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestNewHandler verifies that the new health handler returns a 200 OK status.
func TestNewHandler(t *testing.T) {
	// Create a new HTTP request. The method and URL don't affect the handler in this case.
	req := httptest.NewRequest(http.MethodGet, "http://localhost/health", nil)

	// Create a ResponseRecorder to capture the response.
	recorder := httptest.NewRecorder()

	// Obtain the handler under test.
	handler := NewHandler()

	// Call the handler with our recorder and request.
	handler(recorder, req)

	// Check the status code is what we expect.
	if got, want := recorder.Code, http.StatusOK; got != want {
		t.Errorf("handler returned wrong status code: got %d, want %d", got, want)
	}
}
