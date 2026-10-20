# frozen_string_literal: true

require "mini_magick"
require "fileutils"

module Rewind
  module Services
    module Avatar
      SIZE = 250
      Error = Class.new(Rewind::Error)

      def self.write(user, uploaded)
        raise Error, "No file uploaded" unless uploaded && uploaded[:tempfile]

        FileUtils.mkdir_p(Rewind.config.avatars_dir)
        path = Rewind.config.avatar_path(user.id)

        image = MiniMagick::Image.read(uploaded[:tempfile])

        if image.width.to_i.zero? || image.height.to_i.zero?
          raise Error,
                "Invalid image"
        end

        image.combine_options do |c|
          c.auto_orient
          c.resize "#{SIZE}x#{SIZE}^"
          c.gravity "center"
          c.extent "#{SIZE}x#{SIZE}"
          c.strip
          c.quality 85
        end
        image.format "jpeg"
        image.write(path)
        path
      rescue MiniMagick::Invalid, MiniMagick::Error => error
        raise Error, "Could not process image: #{error.message}"
      end

      def self.delete(user)
        path = Rewind.config.avatar_path(user.id)
        FileUtils.rm_f(path)
      end

      def self.path_for(user)
        path = Rewind.config.avatar_path(user.id)
        File.exist?(path) ? path : nil
      end
    end
  end
end
