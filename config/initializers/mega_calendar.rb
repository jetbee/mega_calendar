# frozen_string_literal: true

module MegaCalendar
  class Configuration
    # default settings for mega calendar
    DEFAULT_SETTINGS = {
      timezone: 'Asia/Tokyo'  # デフォルトのタイムゾーン
    }.freeze

    class << self
      def settings
        @settings ||= DEFAULT_SETTINGS.dup
      end

      def configure
        yield settings if block_given?
      end
    end
  end
end 