/// The coding agents whose sessions Džep brings to the phone (lib/live.dart):
/// what a new session from the phone starts, how notifications and the phone
/// name a session, and how its dialogs are answered.
enum Agent {
  omp('omp'),
  claude('Claude');

  const Agent(this.label);

  /// How the phone and notifications name it: "Claude finished".
  final String label;

  /// What a shell starts it with, which is also the program the terminal reports.
  String get command => name;

  /// A prompt sent while it works steers the run (omp); Claude Code queues it
  /// until the run ends.
  bool get steers => this == omp;

  /// [name] as it travels; omp for anything else (an older peer sends none).
  static Agent parse(Object? name) => values.asNameMap()[name] ?? omp;

  /// The agent a terminal window's foreground [program] is, if it is one.
  static Agent? ofProgram(String program) => values.asNameMap()[program];
}
