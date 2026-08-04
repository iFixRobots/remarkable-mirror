package device

const xochitlService = "xochitl.service"

type systemctlRunner func(action, unit string) error

func runIntentionalXochitlRestartWith(
	run systemctlRunner,
	action string,
	actionErrorCode string,
) error {
	if err := run("reset-failed", xochitlService); err != nil {
		return codedError{code: "xochitl_restart_budget_reset_failed"}
	}
	if err := run(action, xochitlService); err != nil {
		return codedError{code: actionErrorCode}
	}
	return nil
}
