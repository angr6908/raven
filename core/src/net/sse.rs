use axum::body::{Body, Bytes};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::{Stream, StreamExt};
use serde_json::Value;
use std::error::Error;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::sync::mpsc;

use super::error::ApiError;

pub const MAX_EVENT_LINE: usize = 16 << 20;

pub fn sse_headers() -> [(header::HeaderName, HeaderValue); 4] {
    [
        (
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/event-stream"),
        ),
        (header::CACHE_CONTROL, HeaderValue::from_static("no-cache")),
        (header::CONNECTION, HeaderValue::from_static("keep-alive")),
        (
            header::HeaderName::from_static("x-accel-buffering"),
            HeaderValue::from_static("no"),
        ),
    ]
}

pub enum StreamFrame {
    Data(Vec<u8>),
    PreFailure(ApiError),
    Done,
}

pub type FrameSender = mpsc::UnboundedSender<StreamFrame>;
pub type FrameReceiver = mpsc::UnboundedReceiver<StreamFrame>;

pub fn frame_channel() -> (FrameSender, FrameReceiver) {
    mpsc::unbounded_channel()
}

pub fn send_data(sender: &FrameSender, payload: impl Into<Vec<u8>>) {
    let _ = sender.send(StreamFrame::Data(payload.into()));
}

pub fn send_event(sender: &FrameSender, name: &str, data: &Value) {
    let body = serde_json::to_string(data).unwrap_or_default();
    send_data(sender, format!("event: {name}\ndata: {body}\n\n"));
}

pub fn send_data_event(sender: &FrameSender, data: &Value) {
    let body = serde_json::to_string(data).unwrap_or_default();
    send_data(sender, format!("data: {body}\n\n"));
}

pub fn send_done(sender: &FrameSender) {
    send_data(sender, "data: [DONE]\n\n");
}

pub struct SseReader {
    stream: Pin<Box<dyn Stream<Item = reqwest::Result<Bytes>> + Send>>,
    buffer: Vec<u8>,
    finished: bool,
    error: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tail {
    Emit,
    Drop,
}

impl SseReader {
    pub fn new(response: reqwest::Response) -> Self {
        Self {
            stream: Box::pin(response.bytes_stream()),
            buffer: Vec::new(),
            finished: false,
            error: None,
        }
    }

    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    pub async fn next_line(&mut self) -> Option<String> {
        self.next_unit(line_end, Tail::Emit).await
    }

    pub async fn next_block(&mut self) -> Option<String> {
        self.next_unit(block_end, Tail::Drop).await
    }

    async fn next_unit(&mut self, split: fn(&[u8]) -> Option<usize>, tail: Tail) -> Option<String> {
        loop {
            if let Some(end) = split(&self.buffer) {
                let unit: Vec<u8> = self.buffer.drain(..end).collect();
                return Some(String::from_utf8_lossy(&unit).into_owned());
            }
            if self.finished {
                let rest = std::mem::take(&mut self.buffer);
                if tail == Tail::Drop || rest.is_empty() {
                    return None;
                }
                return Some(String::from_utf8_lossy(&rest).into_owned());
            }
            match self.stream.next().await {
                Some(Ok(chunk)) => {
                    if self.buffer.len() + chunk.len() > MAX_EVENT_LINE {
                        self.fail("upstream event line exceeded 16 MiB".to_string());
                    } else {
                        self.buffer.extend_from_slice(&chunk);
                    }
                }
                Some(Err(err)) => self.fail(format!("read upstream stream: {err}")),
                None => self.finished = true,
            }
        }
    }

    fn fail(&mut self, message: String) {
        self.error = Some(message);
        self.finished = true;
        self.buffer.clear();
    }
}

fn line_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .iter()
        .position(|&byte| byte == b'\n')
        .map(|index| index + 1)
}

fn block_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|index| index + 2)
}

pub fn data_payload(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with(':') || trimmed.starts_with("event:") {
        return None;
    }
    let payload = trimmed.strip_prefix("data:").map_or(trimmed, str::trim);
    (!payload.is_empty()).then_some(payload)
}

pub fn parse_block(block: &str) -> (Option<String>, Option<Value>) {
    let name = block
        .lines()
        .find_map(|line| line.strip_prefix("event:"))
        .map(|name| name.trim().to_string());
    let data: Vec<&str> = block
        .lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .map(|line| line.strip_prefix(' ').unwrap_or(line))
        .collect();
    if data.is_empty() {
        return (name, None);
    }
    (name, serde_json::from_str(&data.join("\n")).ok())
}

pub struct FrameBody {
    first: Option<Result<Bytes, Box<dyn Error + Send + Sync>>>,
    receiver: FrameReceiver,
}

impl FrameBody {
    pub fn new(
        first: Option<Result<Bytes, Box<dyn Error + Send + Sync>>>,
        receiver: FrameReceiver,
    ) -> Self {
        Self { first, receiver }
    }
}

impl Stream for FrameBody {
    type Item = Result<Bytes, Box<dyn Error + Send + Sync>>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if let Some(first) = self.first.take() {
            return Poll::Ready(Some(first));
        }
        match self.receiver.poll_recv(cx) {
            Poll::Ready(Some(StreamFrame::Data(data))) => Poll::Ready(Some(Ok(Bytes::from(data)))),
            Poll::Ready(Some(StreamFrame::PreFailure(err))) => Poll::Ready(Some(Err(format!(
                "{}: {}",
                err.code, err.message
            )
            .into()))),
            Poll::Ready(Some(StreamFrame::Done)) | Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

pub async fn first_frame(mut receiver: FrameReceiver) -> Result<Response, Option<ApiError>> {
    match receiver.recv().await {
        Some(StreamFrame::Data(first)) => {
            let body = Body::from_stream(FrameBody::new(Some(Ok(Bytes::from(first))), receiver));
            Ok((StatusCode::OK, sse_headers(), body).into_response())
        }
        Some(StreamFrame::PreFailure(err)) => Err(Some(err)),
        Some(StreamFrame::Done) | None => Err(None),
    }
}

pub async fn first_frame_response(
    receiver: FrameReceiver,
    on_failure: impl FnOnce(ApiError) -> Response,
    on_empty: impl FnOnce() -> Response,
) -> Response {
    match first_frame(receiver).await {
        Ok(response) => response,
        Err(Some(err)) => on_failure(err),
        Err(None) => on_empty(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_payload_skips_comments_and_field_lines() {
        assert_eq!(data_payload("data: {\"a\":1}"), Some("{\"a\":1}"));
        assert_eq!(data_payload("data:[DONE]"), Some("[DONE]"));
        assert_eq!(data_payload(": keep-alive"), None);
        assert_eq!(data_payload("event: response.completed"), None);
        assert_eq!(data_payload("   "), None);
        assert_eq!(data_payload("bare"), Some("bare"));
    }

    #[test]
    fn parse_block_joins_multiline_data() {
        let (name, data) = parse_block("event: msg\ndata: {\"a\":\ndata: 1}\n\n");
        assert_eq!(name.as_deref(), Some("msg"));
        assert_eq!(data.unwrap()["a"], 1);

        let (name, data) = parse_block("event: msg\ndata: {\"a\":1}\n\n");
        assert_eq!(name.as_deref(), Some("msg"));
        assert_eq!(data.unwrap()["a"], 1);

        let (name, data) = parse_block("data: {\"b\":2}\n\n");
        assert!(name.is_none());
        assert_eq!(data.unwrap()["b"], 2);
    }
}
