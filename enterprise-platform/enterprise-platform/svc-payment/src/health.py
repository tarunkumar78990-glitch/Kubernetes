"""Health state shared across the app.

Liveness and readiness are NOT the same thing:
  /healthz - am I broken beyond repair? restart me.
  /readyz  - can I serve traffic right now? if not, take me out of the
             Service endpoints but do NOT restart me.
Checking dependencies in liveness causes restart storms during an outage.
"""


class HealthState:
    def __init__(self):
        self.ready = False
        self.shutting_down = False


state = HealthState()
