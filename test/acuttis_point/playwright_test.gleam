import acuttis_point/browser
import acuttis_point/playwright

pub fn every_failure_kind_maps_to_a_typed_error_test() {
  assert playwright.classify(#("launch", "no chromium"))
    == browser.LaunchFailed("no chromium")
  assert playwright.classify(#("unreachable", "dns failure"))
    == browser.Unreachable("dns failure")
  assert playwright.classify(#("timeout", "loading the dashboard"))
    == browser.TimedOut("loading the dashboard")
  assert playwright.classify(#("auth", "still on the sign-in page"))
    == browser.AuthenticationRejected("still on the sign-in page")
  assert playwright.classify(#("expired", "")) == browser.SessionExpired
  assert playwright.classify(#("interface", "the punch trigger"))
    == browser.InterfaceChanged("the punch trigger")
  assert playwright.classify(#("unavailable", "the button is disabled"))
    == browser.PunchUnavailable("the button is disabled")
}

pub fn an_unknown_kind_is_still_a_failure_test() {
  assert playwright.classify(#("something-new", "who knows"))
    == browser.UnexpectedResponse("who knows")
}
