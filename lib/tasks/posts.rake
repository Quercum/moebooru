def get_metatags(tags)
  metatags, tags = tags.scan(/\S+/).partition {|x| x=~ /^(?:rating):/}
  ret = {}
  metatags.each do |metatag|
    case metatag
    when /^rating:([qse])/
      ret[:rating] ||= $1
    end
  end

  return ret
end

namespace :posts do
  desc 'Recalculate all post votes'
  task :recalc_votes => :environment do
    Post.recalculate_score
  end

  desc 'Set missing CRC32s'
  task :set_crc32 => :environment do
    Post.find(:all, :order => "ID ASC", :conditions => "crc32 IS NULL OR (sample_width IS NOT NULL AND sample_crc32 IS NULL)").each do |post|
      p "Post #{post.id}..."
      old_md5 = post.md5

      # Older deleted posts will have been deleted from disk.  Tolerate the error from this;
      # just leave the CRCs null.
      begin
        post.regenerate_hash
        post.generate_sample_hash
      rescue SocketError, URI::Error, Timeout::Error, SystemCallError => x
        next
      end

      if old_md5 != post.md5
        # Changing the MD5 would break the file path, and we only care about populating
        # CRC32.
        p "warning: post #{post.id} MD5 is incorrect; got #{post.md5}, expected #{old_md5} (corrupted file?)"
        old_md5 = post.md5
      end
      post.save!
    end
  end

  desc 'Add missing tag history data'
  task :add_post_history => :environment do
    # Add missing metatags to post_tag_history, using the nearest data (nearby tag
    # history or the post itself).  We won't break if this is missing, but this data
    # will be added on the next change for every post, which will make it look like
    # people are making changes that they're not.
    PostTagHistory.transaction do
      PostTagHistory.find(:all, :order => "id ASC").each do |change|
      #:all, :order => "id ASC").each
        post = Post.find(change.post_id)
        next_change = change.next
        if next_change
          next_change = next_change.tags
        else
          next_change = ""
        end

        prev_change = change.previous
        if prev_change
          prev_change = prev_change.tags
        else
          prev_change = ""
        end

        sources = [prev_change, next_change, post.cached_tags_versioned].map { |x| get_metatags(x) }
        current_metatags = get_metatags(change.tags)

        metatags_to_add = []
        [:rating].each do |metatag|
          next if current_metatags[metatag]
          val = nil
          sources.each { |source| val ||= source[metatag] }

          metatags_to_add += [metatag.to_s + ":" + val]
        end

        next if metatags_to_add.empty?
        change.tags = (metatags_to_add + [change.tags]).join(" ")
        change.save!
      end
    end
  end

  desc 'Upload posts to mirrors'
  task :mirror => :environment do
    Post.find(:all, :conditions => ["NOT is_warehoused AND status <> 'deleted'"], :order => "id DESC").each { |post|
      p "Mirroring ##{post.id}..."
      post.upload_to_mirrors
    }
  end
end
