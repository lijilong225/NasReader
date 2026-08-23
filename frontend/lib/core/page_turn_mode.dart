enum PageTurnMode {
  none('无动画'),
  cover('覆盖'),
  slide('滑动'),
  scroll('上下滚动');

  final String label;
  const PageTurnMode(this.label);
}