# frozen_string_literal: true

class SendSubmissionArchivedWebhookRequestJob
  include Sidekiq::Job

  sidekiq_options queue: :webhooks

  USER_AGENT = 'DocuSeal.com Webhook'

  MAX_ATTEMPTS = 10

  def perform(params = {})
    submission = Submission.find(params['submission_id'])
    webhook_url = WebhookUrl.find(params['webhook_url_id'])

    attempt = params['attempt'].to_i

    return if webhook_url.url.blank? || webhook_url.events.exclude?('submission.archived')

    resp = begin
      Faraday.post(webhook_url.url,
                   {
                     event_type: 'submission.archived',
                     timestamp: Time.current,
                     data: submission.as_json(only: %i[id archived_at])
                   }.to_json,
                   **webhook_url.secret.to_h,
                   'Content-Type' => 'application/json',
                   'User-Agent' => USER_AGENT)
    rescue Faraday::Error
      nil
    end

    if (resp.nil? || resp.status.to_i >= 400) && attempt <= MAX_ATTEMPTS &&
       (!Docuseal.multitenant? || submission.account.account_configs.exists?(key: :plan))
      SendSubmissionArchivedWebhookRequestJob.perform_in((2**attempt).minutes, {
                                                           'submission_id' => submission.id,
                                                           'webhook_url_id' => webhook_url.id,
                                                           'attempt' => attempt + 1,
                                                           'last_status' => resp&.status.to_i
                                                         })
    end
  end
end
