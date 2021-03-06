require "digest/sha1"
require_dependency "file_helper"
require_dependency "url_helper"
require_dependency "db_helper"
require_dependency "validators/upload_validator"
require_dependency "file_store/local_store"

class Upload < ActiveRecord::Base
  belongs_to :user

  has_many :post_uploads, dependent: :destroy
  has_many :posts, through: :post_uploads

  has_many :optimized_images, dependent: :destroy

  attr_accessor :for_group_message
  attr_accessor :for_theme
  attr_accessor :for_private_message

  validates_presence_of :filesize
  validates_presence_of :original_filename

  validates_with ::Validators::UploadValidator

  def thumbnail(width = self.width, height = self.height)
    optimized_images.find_by(width: width, height: height)
  end

  def has_thumbnail?(width, height)
    thumbnail(width, height).present?
  end

  def create_thumbnail!(width, height, crop = false)
    return unless SiteSetting.create_thumbnails?

    opts = {
      filename: self.original_filename,
      allow_animation: SiteSetting.allow_animated_thumbnails,
      crop: crop
    }

    if _thumbnail = OptimizedImage.create_for(self, width, height, opts)
      self.width = width
      self.height = height
      save(validate: false)
    end
  end

  def destroy
    Upload.transaction do
      Discourse.store.remove_upload(self)
      super
    end
  end

  def self.generate_digest(path)
    Digest::SHA1.file(path).hexdigest
  end

  def self.get_from_url(url)
    return if url.blank?
    # we store relative urls, so we need to remove any host/cdn
    url = url.sub(Discourse.asset_host, "") if Discourse.asset_host.present?
    # when using s3, we need to replace with the absolute base url
    url = url.sub(SiteSetting.s3_cdn_url, Discourse.store.absolute_base_url) if SiteSetting.s3_cdn_url.present?

    # always try to get the path
    uri = URI(url) rescue nil
    url = uri.path if uri.try(:scheme)

    Upload.find_by(url: url)
  end

  def self.migrate_to_new_scheme(limit = nil)
    problems = []

    if SiteSetting.migrate_to_new_scheme
      max_file_size_kb = [SiteSetting.max_image_size_kb, SiteSetting.max_attachment_size_kb].max.kilobytes
      local_store = FileStore::LocalStore.new

      scope = Upload.where("url NOT LIKE '%/original/_X/%'").order(id: :desc)
      scope.limit(limit) if limit

      scope.each do |upload|
        begin
          # keep track of the url
          previous_url = upload.url.dup
          # where is the file currently stored?
          external = previous_url =~ /^\/\//
          # download if external
          if external
            url = SiteSetting.scheme + ":" + previous_url
            file = FileHelper.download(
              url,
              max_file_size: max_file_size_kb,
              tmp_file_name: "discourse",
              follow_redirect: true
            ) rescue nil
            path = file.path
          else
            path = local_store.path_for(upload)
          end
          # compute SHA if missing
          if upload.sha1.blank?
            upload.sha1 = Upload.generate_digest(path)
          end
          # optimize if image
          FileHelper.optimize_image!(path) if FileHelper.is_image?(File.basename(path))
          # store to new location & update the filesize
          File.open(path) do |f|
            upload.url = Discourse.store.store_upload(f, upload)
            upload.filesize = f.size
            upload.save!
          end
          # remap the URLs
          DbHelper.remap(UrlHelper.absolute(previous_url), upload.url) unless external
          DbHelper.remap(previous_url, upload.url)
          # remove the old file (when local)
          unless external
            FileUtils.rm(path, force: true) rescue nil
          end
        rescue => e
          problems << { upload: upload, ex: e }
        ensure
          file.try(:unlink) rescue nil
          file.try(:close) rescue nil
        end
      end
    end

    problems
  end

end

# == Schema Information
#
# Table name: uploads
#
#  id                :integer          not null, primary key
#  user_id           :integer          not null
#  original_filename :string           not null
#  filesize          :integer          not null
#  width             :integer
#  height            :integer
#  url               :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  sha1              :string(40)
#  origin            :string(1000)
#  retain_hours      :integer
#  extension         :string(10)
#
# Indexes
#
#  index_uploads_on_id_and_url  (id,url)
#  index_uploads_on_sha1        (sha1) UNIQUE
#  index_uploads_on_url         (url)
#  index_uploads_on_user_id     (user_id)
#
