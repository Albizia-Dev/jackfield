// Import Jackfield into the application's own worker; keep other worker handlers here.
importScripts('./assets/packages/jackfield/web/jackfield_worker.js');
JackfieldWorker.install({ leaseMs: 45000, heartbeatMs: 15000 });
