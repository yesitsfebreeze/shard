//! AI module - defines AI client trait and mock implementation

use async_trait::async_trait;

/// Context for AI query
#[derive(Clone, Debug)]
pub struct QueryContext {
    /// File path being edited
    pub file_path: String,
    /// Current line number (0-indexed)
    pub current_line: usize,
    /// Lines around cursor for context
    pub surrounding_lines: Vec<String>,
    /// Full file content
    pub file_content: String,
}

/// AI query errors
#[derive(Debug, Clone)]
pub enum QueryError {
    Timeout,
    NetworkError(String),
    InvalidResponse,
    ShardUnavailable,
}

impl std::fmt::Display for QueryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            QueryError::Timeout => write!(f, "AI query timed out"),
            QueryError::NetworkError(e) => write!(f, "Network error: {}", e),
            QueryError::InvalidResponse => write!(f, "Invalid response from AI"),
            QueryError::ShardUnavailable => write!(f, "Shard service unavailable"),
        }
    }
}

impl std::error::Error for QueryError {}

/// AI client trait - defines interface for AI queries
#[async_trait]
pub trait AiClient: Send + Sync {
    /// Query AI with a question about the code
    async fn query_shard(&self, question: &str, context: QueryContext) -> Result<String, QueryError>;

    /// Query AI for next steps suggestion
    async fn query_next_steps(&self, context: QueryContext) -> Result<String, QueryError>;
}

/// Mock AI client for testing (Phase 1/2)
pub struct MockAiClient;

#[async_trait]
impl AiClient for MockAiClient {
    async fn query_shard(&self, question: &str, _context: QueryContext) -> Result<String, QueryError> {
        // Simulate response latency
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Return mock response based on question
        let response = if question.to_lowercase().contains("error") {
            "To handle errors in Rust, use Result<T, E> or Option<T>.\nPattern match on the result to handle success and failure cases.".to_string()
        } else if question.to_lowercase().contains("function") {
            "Functions in Rust are defined with `fn` keyword.\nYou can specify return types with `->`.".to_string()
        } else {
            format!("Mock response to: {}", question)
        };

        Ok(response)
    }

    async fn query_next_steps(&self, _context: QueryContext) -> Result<String, QueryError> {
        // Simulate response latency
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        Ok("Next: Add error handling to the main function".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_mock_ai_query() {
        let client = MockAiClient;
        let context = QueryContext {
            file_path: "test.rs".to_string(),
            current_line: 0,
            surrounding_lines: vec![],
            file_content: "fn main() {}".to_string(),
        };

        let response = client.query_shard("How do I handle errors?", context).await;
        assert!(response.is_ok());
        assert!(response.unwrap().contains("Result"));
    }

    #[tokio::test]
    async fn test_mock_next_steps() {
        let client = MockAiClient;
        let context = QueryContext {
            file_path: "test.rs".to_string(),
            current_line: 0,
            surrounding_lines: vec![],
            file_content: "fn main() {}".to_string(),
        };

        let response = client.query_next_steps(context).await;
        assert!(response.is_ok());
    }
}
