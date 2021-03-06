# encoding: utf-8
#
# Licensed to the Software Freedom Conservancy (SFC) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The SFC licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require 'json'

module Selenium
  module WebDriver
    module Remote
      #
      # Low level bridge to the remote server, through which the rest of the API works.
      #
      # @api private
      #

      class W3CBridge
        include BridgeHelper
        include Atoms

        attr_accessor :context, :http, :file_detector
        attr_reader :capabilities

        #
        # Initializes the bridge with the given server URL.
        #
        # @param url         [String] url for the remote server
        # @param http_client [Object] an HTTP client instance that implements the same protocol as Http::Default
        # @param desired_capabilities [Capabilities] an instance of Remote::Capabilities describing the capabilities you want
        #

        def initialize(opts = {})

          opts = opts.dup

          port = opts.delete(:port) || 4444
          http_client = opts.delete(:http_client) { Http::Default.new }
          desired_capabilities = opts.delete(:desired_capabilities) { W3CCapabilities.firefox }
          url = opts.delete(:url) { "http://#{Platform.localhost}:#{port}/wd/hub" }

          desired_capabilities = W3CCapabilities.send(desired_capabilities) if desired_capabilities.is_a? Symbol

          desired_capabilities[:marionette] = opts.delete(:marionette) unless opts[:marionette].nil?

          unless opts.empty?
            raise ArgumentError, "unknown option#{'s' if opts.size != 1}: #{opts.inspect}"
          end

          uri = url.is_a?(URI) ? url : URI.parse(url)
          uri.path += '/' unless uri.path =~ %r{\/$}

          http_client.server_url = uri

          @http = http_client
          @capabilities = create_session(desired_capabilities)
          @file_detector = nil
        end

        def browser
          @browser ||= (
          name = @capabilities.browser_name
          name ? name.tr(' ', '_').to_sym : 'unknown'
          )
        end

        def driver_extensions
          [
            DriverExtensions::UploadsFiles,
            DriverExtensions::TakesScreenshot,
            DriverExtensions::HasSessionId,
            DriverExtensions::Rotatable,
            DriverExtensions::HasRemoteStatus,
            DriverExtensions::HasWebStorage
          ]
        end

        def commands(command)
          case command
          when :status, :is_element_displayed
            Bridge::COMMANDS[command]
          else
            COMMANDS[command]
          end
        end

        #
        # Returns the current session ID.
        #

        def session_id
          @session_id || raise(Error::WebDriverError, 'no current session exists')
        end

        def create_session(desired_capabilities)
          resp = raw_execute :new_session, {}, {desiredCapabilities: desired_capabilities}
          @session_id = resp['sessionId']
          return W3CCapabilities.json_create resp['value'] if @session_id

          raise Error::WebDriverError, 'no sessionId in returned payload'
        end

        def status
          execute :status
        end

        def get(url)
          execute :get, {}, {url: url}
        end

        def implicit_wait_timeout=(milliseconds)
          timeout('implicit', milliseconds)
        end

        def script_timeout=(milliseconds)
          timeout('script', milliseconds)
        end

        def timeout(type, milliseconds)
          execute :set_timeout, {}, {type: type, ms: milliseconds}
        end

        #
        # alerts
        #

        def accept_alert
          execute :accept_alert
        end

        def dismiss_alert
          execute :dismiss_alert
        end

        def alert=(keys)
          execute :send_alert_text, {}, {value: keys.split(//)}
        end

        def alert_text
          execute :get_alert_text
        end

        #
        # navigation
        #

        def go_back
          execute :back
        end

        def go_forward
          execute :forward
        end

        def url
          execute :get_current_url
        end

        def title
          execute :get_title
        end

        def page_source
          execute_script('var source = document.documentElement.outerHTML;' \
                            'if (!source) { source = new XMLSerializer().serializeToString(document); }' \
                            'return source;')
        end

        def switch_to_window(name)
          execute :switch_to_window, {}, {handle: name}
        end

        def switch_to_frame(id)
          id = find_element_by('id', id) if id.is_a? String
          execute :switch_to_frame, {}, {id: id}
        end

        def switch_to_parent_frame
          execute :switch_to_parent_frame
        end

        def switch_to_default_content
          switch_to_frame nil
        end

        QUIT_ERRORS = [IOError].freeze

        def quit
          execute :delete_session
          http.close
        rescue *QUIT_ERRORS
        end

        def close
          execute :close_window
        end

        def refresh
          execute :refresh
        end

        #
        # window handling
        #

        def window_handles
          execute :get_window_handles
        end

        def window_handle
          execute :get_window_handle
        end

        def resize_window(width, height, handle = :current)
          unless handle == :current
            raise Error::WebDriverError, 'Switch to desired window before changing its size'
          end
          execute :set_window_size, {}, {width: width,
                                       height: height}
        end

        def maximize_window(handle = :current)
          unless handle == :current
            raise Error::UnsupportedOperationError, 'Switch to desired window before changing its size'
          end
          execute :maximize_window
        end

        def full_screen_window
          execute :fullscreen_window
        end

        def window_size(handle = :current)
          unless handle == :current
            raise Error::UnsupportedOperationError, 'Switch to desired window before getting its size'
          end
          data = execute :get_window_size

          Dimension.new data['width'], data['height']
        end

        def reposition_window(x, y)
          execute :set_window_position, {}, {x: x, y: y}
        end

        def window_position
          data = execute :get_window_position
          Point.new data['x'], data['y']
        end

        def screenshot
          execute :take_screenshot
        end

        #
        # HTML 5
        #

        def local_storage_item(key, value = nil)
          if value
            execute_script("localStorage.setItem('#{key}', '#{value}')")
          else
            execute_script("return localStorage.getItem('#{key}')")
          end
        end

        def remove_local_storage_item(key)
          execute_script("localStorage.removeItem('#{key}')")
        end

        def local_storage_keys
          execute_script('return Object.keys(localStorage)')
        end

        def clear_local_storage
          execute_script('localStorage.clear()')
        end

        def local_storage_size
          execute_script('return localStorage.length')
        end

        def session_storage_item(key, value = nil)
          if value
            execute_script("sessionStorage.setItem('#{key}', '#{value}')")
          else
            execute_script("return sessionStorage.getItem('#{key}')")
          end
        end

        def remove_session_storage_item(key)
          execute_script("sessionStorage.removeItem('#{key}')")
        end

        def session_storage_keys
          execute_script('return Object.keys(sessionStorage)')
        end

        def clear_session_storage
          execute_script('sessionStorage.clear()')
        end

        def session_storage_size
          execute_script('return sessionStorage.length')
        end

        def location
          raise Error::UnsupportedOperationError, 'The W3C standard does not currently support getting location'
        end

        def set_location(_lat, _lon, _alt)
          raise Error::UnsupportedOperationError, 'The W3C standard does not currently support setting location'
        end

        def network_connection
          raise Error::UnsupportedOperationError, 'The W3C standard does not currently support getting network connection'
        end

        def network_connection=(_type)
          raise Error::UnsupportedOperationError, 'The W3C standard does not currently support setting network connection'
        end

        #
        # javascript execution
        #

        def execute_script(script, *args)
          result = execute :execute_script, {}, {script: script, args: args}
          unwrap_script_result result
        end

        def execute_async_script(script, *args)
          result = execute :execute_async_script, {}, {script: script, args: args}
          unwrap_script_result result
        end

        #
        # cookies
        #

        def options
          @options ||= WebDriver::W3COptions.new(self)
        end

        def add_cookie(cookie)
          execute :add_cookie, {}, {cookie: cookie}
        end

        def delete_cookie(name)
          execute :delete_cookie, name: name
        end

        def cookie(name)
          execute :get_cookie, name: name
        end

        def cookies
          execute :get_all_cookies
        end

        def delete_all_cookies
          execute :delete_all_cookies
        end

        #
        # actions
        #

        def action(async = false)
          W3CActionBuilder.new self,
                               Interactions.pointer(:mouse, name: 'mouse'),
                               Interactions.key('keyboard'),
                               async
        end
        alias_method :actions, :action

        def mouse
          raise Error::UnsupportedOperationError, '#mouse is no longer supported, use #action instead'
        end

        def keyboard
          raise Error::UnsupportedOperationError, '#keyboard is no longer supported, use #action instead'
        end

        def send_actions(data)
          execute :actions, {}, {actions: data}
        end

        def release_actions
          execute :release_actions
        end

        def click_element(element)
          execute :element_click, id: element
        end

        # TODO: - Implement file verification
        def send_keys_to_element(element, keys)
          execute :element_send_keys, {id: element}, {value: keys.join('').split(//)}
        end

        def clear_element(element)
          execute :element_clear, id: element
        end

        def submit_element(element)
          form = find_element_by('xpath', "./ancestor-or-self::form", element)
          execute_script("var e = arguments[0].ownerDocument.createEvent('Event');" \
                            "e.initEvent('submit', true, true);" \
                            'if (arguments[0].dispatchEvent(e)) { arguments[0].submit() }', form.as_json)
        end

        def drag_element(element, right_by, down_by)
          execute :drag_element, {id: element}, {x: right_by, y: down_by}
        end

        def touch_single_tap(element)
          execute :touch_single_tap, {}, {element: element}
        end

        def touch_double_tap(element)
          execute :touch_double_tap, {}, {element: element}
        end

        def touch_long_press(element)
          execute :touch_long_press, {}, {element: element}
        end

        def touch_down(x, y)
          execute :touch_down, {}, {x: x, y: y}
        end

        def touch_up(x, y)
          execute :touch_up, {}, {x: x, y: y}
        end

        def touch_move(x, y)
          execute :touch_move, {}, {x: x, y: y}
        end

        def touch_scroll(element, x, y)
          if element
            execute :touch_scroll, {}, {element: element,
                                       xoffset: x,
                                       yoffset: y}
          else
            execute :touch_scroll, {}, {xoffset: x, yoffset: y}
          end
        end

        def touch_flick(xspeed, yspeed)
          execute :touch_flick, {}, {xspeed: xspeed, yspeed: yspeed}
        end

        def touch_element_flick(element, right_by, down_by, speed)
          execute :touch_flick, {}, {element: element,
                                    xoffset: right_by,
                                    yoffset: down_by,
                                    speed: speed}
        end

        def screen_orientation=(orientation)
          execute :set_screen_orientation, {}, {orientation: orientation}
        end

        def screen_orientation
          execute :get_screen_orientation
        end

        #
        # element properties
        #

        def element_tag_name(element)
          execute :get_element_tag_name, id: element
        end

        def element_attribute(element, name)
          execute_atom :getAttribute, element, name
        end

        def element_property(element, name)
          execute :get_element_property, id: element.ref, name: name
        end

        def element_value(element)
          element_property element, 'value'
        end

        def element_text(element)
          execute :get_element_text, id: element
        end

        def element_location(element)
          data = execute :get_element_rect, id: element

          Point.new data['x'], data['y']
        end

        def element_location_once_scrolled_into_view(element)
          send_keys_to_element(element, [''])
          element_location(element)
        end

        def element_size(element)
          data = execute :get_element_rect, id: element

          Dimension.new data['width'], data['height']
        end

        def element_enabled?(element)
          execute :is_element_enabled, id: element
        end

        def element_selected?(element)
          execute :is_element_selected, id: element
        end

        def element_displayed?(element)
          execute :is_element_displayed, id: element
        end

        def element_value_of_css_property(element, prop)
          execute :get_element_css_value, id: element, property_name: prop
        end

        #
        # finding elements
        #

        def active_element
          Element.new self, element_id_from(execute(:get_active_element))
        end

        alias_method :switch_to_active_element, :active_element

        def find_element_by(how, what, parent = nil)
          how, what = convert_locators(how, what)

          id = if parent
                 execute :find_child_element, {id: parent}, {using: how, value: what}
               else
                 execute :find_element, {}, {using: how, value: what}
               end
          Element.new self, element_id_from(id)
        end

        def find_elements_by(how, what, parent = nil)
          how, what = convert_locators(how, what)

          ids = if parent
                  execute :find_child_elements, {id: parent}, {using: how, value: what}
                else
                  execute :find_elements, {}, {using: how, value: what}
                end

          ids.map { |id| Element.new self, element_id_from(id) }
        end

        private

        def convert_locators(how, what)
          case how
          when 'class name'
            how = 'css selector'
            what = ".#{escape_css(what)}"
          when 'id'
            how = 'css selector'
            what = "##{escape_css(what)}"
          when 'name'
            how = 'css selector'
            what = "*[name='#{escape_css(what)}']"
          when 'tag name'
            how = 'css selector'
          end
          [how, what]
        end

        #
        # executes a command on the remote server.
        #
        #
        # Returns the 'value' of the returned payload
        #

        def execute(*args)
          result = raw_execute(*args)
          result.payload.key?('value') ? result['value'] : result
        end

        #
        # executes a command on the remote server.
        #
        # @return [WebDriver::Remote::Response]
        #

        def raw_execute(command, opts = {}, command_hash = nil)
          verb, path = commands(command) || raise(ArgumentError, "unknown command: #{command.inspect}")
          path = path.dup

          path[':session_id'] = @session_id if path.include?(':session_id')

          begin
            opts.each do |key, value|
              path[key.inspect] = escaper.escape(value.to_s)
            end
          rescue IndexError
            raise ArgumentError, "#{opts.inspect} invalid for #{command.inspect}"
          end

          puts "-> #{verb.to_s.upcase} #{path}" if $DEBUG
          http.call verb, path, command_hash
        end

        def escaper
          @escaper ||= defined?(URI::Parser) ? URI::Parser.new : URI
        end

        ESCAPE_CSS_REGEXP = /(['"\\#.:;,!?+<>=~*^$|%&@`{}\-\[\]\(\)])/
        UNICODE_CODE_POINT = 30

        # Escapes invalid characters in CSS selector.
        # @see https://mathiasbynens.be/notes/css-escapes
        def escape_css(string)
          string = string.gsub(ESCAPE_CSS_REGEXP) { |match| "\\#{match}" }
          if !string.empty? && string[0] =~ /[[:digit:]]/
            string = "\\#{UNICODE_CODE_POINT + Integer(string[0])} #{string[1..-1]}"
          end

          string
        end
      end # W3CBridge
    end # Remote
  end # WebDriver
end # Selenium
