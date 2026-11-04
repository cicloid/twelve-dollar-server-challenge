# frozen_string_literal: true

# Itsi reads this from the working directory (start.sh cds here); start.sh's flags set bind, workers
# and threads. With an Itsi.rb present, Itsi only serves the Rack app named here.
rackup_file "./config.ru"

# Itsi closes a connection that sends no request header for header_read_timeout (2 s by default),
# which includes keep-alive connections idle between requests: load-test users think for longer
# than that, so they'd reconnect for almost every request.
header_read_timeout 75.0
