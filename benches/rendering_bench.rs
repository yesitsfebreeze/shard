use criterion::{black_box, criterion_group, criterion_main, Criterion};
use shards_tui::editor::CursorPosition;
use shards_tui::ui::{render_frame, Viewport};

fn render_frame_benchmark(c: &mut Criterion) {
    let mut lines = Vec::new();
    for i in 0..10000 {
        lines.push(format!("Line {} with some content", i));
    }

    let cursor = CursorPosition::new(5000, 0);
    let viewport = Viewport::new(24);

    c.bench_function("render_10k_lines", |b| {
        b.iter(|| {
            render_frame(
                black_box(&lines),
                black_box(&cursor),
                black_box(&viewport),
                black_box(80),
                black_box(24),
            )
        })
    });
}

criterion_group!(benches, render_frame_benchmark);
criterion_main!(benches);
