enum PageTurnMode {
  cover('平滑覆盖'),
  simulation('仿真翻页'),
  scroll('上下滚动');

  final String label;
  const PageTurnMode(this.label);
}