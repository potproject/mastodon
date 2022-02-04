# frozen_string_literal: true

class Trends::Statuses < Trends::Base
  PREFIX = 'trending_statuses'

  self.default_options = {
    threshold: 5,
    review_threshold: 3,
    score_halflife: 8.hours.freeze,
  }

  def register(status, at_time = Time.now.utc)
    add(status.proper, status.account_id, at_time) if eligible?(status)
  end

  def add(status, _account_id, at_time = Time.now.utc)
    # We rely on the total reblogs count, so we don't record
    # which account did the reblog and when here

    record_used_id(status.id, at_time)
  end

  def get(allowed, limit)
    status_ids = currently_trending_ids(allowed, limit)
    statuses = Status.where(id: status_ids).cache_ids.index_by(&:id)
    status_ids.map { |id| statuses[id] }.compact
  end

  def refresh(at_time = Time.now.utc)
    statuses = Status.where(id: (recently_used_ids(at_time) + currently_trending_ids(false, -1)).uniq).includes(:account, :media_attachments)
    calculate_scores(statuses, at_time)
    trim_older_items
  end

  def request_review
    statuses = Status.where(id: currently_trending_ids(false, -1)).includes(:account)

    statuses_requiring_review = statuses.filter_map do |status|
      next unless would_be_trending?(status.id) && !status.trendable? && status.requires_review_notification?

      status.account.touch(:requested_review_at)
      status
    end

    return if statuses_requiring_review.empty?

    User.staff.includes(:account).find_each do |user|
      AdminMailer.new_trending_statuses(user.account, statuses_requiring_review).deliver_later! if user.allows_trending_tag_emails?
    end
  end

  protected

  def key_prefix
    PREFIX
  end

  private

  def eligible?(status)
    original_status = status.proper

    original_status.public_visibility? &&
      original_status.account.discoverable? && !original_status.account.silenced? &&
      original_status.spoiler_text.blank? && !original_status.sensitive? && !original_status.reply?
  end

  def calculate_scores(statuses, at_time)
    statuses.each do |status|
      expected  = 1.0
      observed  = (status.reblogs_count + status.favourites_count).to_f

      score = begin
        if expected > observed || observed < options[:threshold]
          0
        else
          ((observed - expected)**2) / expected
        end
      end

      decaying_score = score * (0.5**((at_time.to_f - status.created_at.to_f) / options[:score_halflife].to_f))

      if decaying_score.zero?
        redis.zrem("#{PREFIX}:all", status.id)
        redis.zrem("#{PREFIX}:allowed", status.id)
      else
        redis.zadd("#{PREFIX}:all", decaying_score, status.id)

        if status.trendable? && status.account.discoverable?
          redis.zadd("#{PREFIX}:allowed", decaying_score, status.id)
        else
          redis.zrem("#{PREFIX}:allowed", status.id)
        end
      end
    end
  end

  def would_be_trending?(id)
    score(id) > score_at_rank(options[:review_threshold] - 1)
  end
end
