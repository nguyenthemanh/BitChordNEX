export class AppVisibility {
  static hidden: boolean = false;
  static listener: (() => void) | null = null;

  static setHidden(hidden: boolean): void {
    AppVisibility.hidden = hidden;
    const notify = AppVisibility.listener;
    if (notify !== null) {
      notify();
    }
  }
}
