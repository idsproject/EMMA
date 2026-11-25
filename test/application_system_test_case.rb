# test/application_system_test_case.rb
#
# frozen_string_literal: true
# warn_indent:           true

require 'test_helper'
require 'capybara-lockstep'

# Common base for system tests, which validate page contents over sequences of
# actions.
#
# Browser choices are:
#
# - :chrome
# - :chrome_headless
# - :firefox
# - :firefox_headless
#
# Firefox webdriver became problematic for use in tests starting in March 2025.
#
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase

  include TestHelper::SystemTests
  include CapybaraSelect2

  if NO_JAVASCRIPT

    driven_by :rack_test

  else

    HEADLESS    = true
    FAMILY      = :chrome
    BROWSER     = HEADLESS ? :"headless_#{FAMILY}"   : FAMILY
    SCREEN_SIZE = HEADLESS ? [1920, 1080].freeze : [1024, 768].freeze

    driven_by :selenium, using: BROWSER, screen_size: SCREEN_SIZE do |drv_opt|
      if BROWSER.to_s.match?(/Firefox/i)
        drv_opt.add_preference('devtools.jsonview.enabled', false)
      end
    end

  end

  self.use_transactional_tests = false

  # ===========================================================================
  # :section:
  # ===========================================================================

  Capybara::Lockstep.debug   = true?(ENV_VAR['DEBUG_LOCKSTEP'])
  Capybara::Lockstep.timeout = 2 * Capybara.default_max_wait_time

  setup do
    CapybaraLockstep.active = true
  end

  teardown do
    CapybaraLockstep.active = false
  end

end

# Chrome 13x+ rejects origin "*" in the CDP Storage.clearDataForOrigin call
# that Capybara 3.40 makes in ChromeDriver#reset!. Clear cookies for all
# origins and storage for the app server's own origin instead.
require 'capybara/selenium/driver'
module ChromeResetOriginFix
  def execute_cdp(cmd, params = {})
    return super unless cmd == 'Storage.clearDataForOrigin' && params[:origin] == '*'
    super('Network.clearBrowserCookies')
    if (server = Capybara.current_session.server)
      super('Storage.clearDataForOrigin',
            origin: server.base_url, storageTypes: params[:storageTypes])
    end
  end
end
Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeResetOriginFix)

# Run the system tests against an external server (e.g. the Go version)
# by setting APP_HOST, for example APP_HOST=http://localhost:8080.
if (app_host = ENV['APP_HOST']).present?
  Capybara.app_host   = app_host
  Capybara.run_server = false
end
