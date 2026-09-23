/// Whether [now] is later than the last permitted instant [deadline].
bool isPastDeadline(DateTime now, DateTime deadline) => now.isAfter(deadline);
