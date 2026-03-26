use criterion::{black_box, criterion_group, criterion_main, Criterion};
use shards_tui::editor::CursorPosition;

fn cursor_movement_benchmark(c: &mut Criterion) {
    let lines = vec!["test line".to_string(); 10000];

    c.bench_function("move_down_1000_times", |b| {
        b.iter(|| {
            let mut cursor = CursorPosition::new(5000, 0);
            for _ in 0..1000 {
                cursor.move_down(black_box(&lines));
            }
        })
    });

    c.bench_function("move_up_1000_times", |b| {
        b.iter(|| {
            let mut cursor = CursorPosition::new(5000, 0);
            for _ in 0..1000 {
                cursor.move_up(black_box(&lines));
            }
        })
    });
}

criterion_group!(benches, cursor_movement_benchmark);
criterion_main!(benches);
