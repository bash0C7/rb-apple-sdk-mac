#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

# Adapt to the actual Vision API shape the bridge surfaces.
puts Apple::Vision.constants.first(10).inspect
