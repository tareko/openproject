# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module Llm
  # Single entry point for keeping the semantic index current. Both paths share
  # index_window, run inside a GoodJob batch and differ only in the window they
  # consider: enqueued with a semantic_index_id (admin-triggered) the window is
  # unbounded, i.e. a full re-index; enqueued without arguments by the cron
  # schedule the window starts at semantic_indexes.last_indexing_started_at, so
  # only the active index is synced and only work packages created or
  # text-changed since the last run are embedded. Without an active index the
  # cron path is a no-op. FinishSemanticIndexingJob advances the watermark when a
  # batch finishes without failed embed jobs, so a failed run leaves the previous
  # watermark and the next run re-covers its window. Both paths claim the index
  # via SemanticIndex#start_indexing!, whose row lock allows only one unfinished
  # batch per index, so the cron skips a tick while a previous run's batch is
  # unfinished, since that run advances the watermark itself. The derived
  # "indexing" status (and its progress display) covers cron syncs like full runs.
  class IndexWorkPackagesJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Batches
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_with_priority :low

    # At most one indexing job performs at a time; queued ticks simply wait and
    # then no-op if another run holds the claim.
    good_job_control_concurrency_with(total_limit: 1)

    BATCH_SIZE = 100

    def self.current_db_time
      # DB clock, like the journal SQL: the watermark is compared against
      # updated_at values written by app servers, so it must not depend on
      # this runner's clock. clock_timestamp() because NOW() would freeze at
      # transaction start.
      # TODO: i think this could be NOW()
      ActiveRecord::Base.connection.select_value("SELECT clock_timestamp()")
    end

    def perform(semantic_index_id = nil)
      return unless OpenProject::Llm::Features[:semantic_search].available?

      full_index? = semantic_index_id.present?

      semantic_index_id ||= SemanticIndex.active_id

      semantic_index = SemanticIndex.find_by(id: semantic_index_id)

      return if semantic_index.blank?

      # A previous run is still in progress: it advances the watermark itself once
      # its batch finishes, so the cron waits instead of embedding the same work
      # packages twice.
      return if !full_index? && semantic_index.indexing?

      return record_prerequisite_error(semantic_index) unless prerequisites_met?(semantic_index)

      window_begin = full_index? ? nil : semantic_index.last_indexing_started_at

      batch = GoodJob::Batch.enqueue(on_finish: Llm::FinishSemanticIndexingJob,
                             semantic_index_id: semantic_index.id,
                             full_index:,
                             # captured at creation time: the batch covers everything up to
                             # its own execution, so an earlier watermark only causes
                             # idempotent re-embeds. Set on the index when the batch finishes
                             # successfully.
                             window_started_at: current_db_time )

      semantic_index.start_indexing!
      batch.add {index_window(semantic_index, window_begin)}
    end


    private


    # TODO: rename "window" to something better
    def index_window(semantic_index, window_begin)
      now = self.class.current_db_time
      window = window_begin..now
      WorkPackage
        .where(updated_at: window)
        .find_in_batches(batch_size: BATCH_SIZE) do |work_packages|
          embed_changed_text(semantic_index, work_packages.map(&:id), window)
        end

      now
    end

    def embed_changed_text(semantic_index, work_package_ids, window)
      relevant_ids = work_package_ids_with_text_changes(work_package_ids, window)
      return if relevant_ids.empty?

      Llm::EmbedWorkPackagesJob.perform_later(semantic_index.id, relevant_ids)
    end

    # Second query, per candidate batch, through the existing journals.journable_id
    # index — no new journal index needed. Journals are matched on updated_at, not
    # created_at: aggregation refills the predecessor journal row on every save, so
    # updated_at is when the change happened and always equals work_packages.updated_at.
    # With an unbounded window every journal qualifies, so a full pass embeds all.
    def work_package_ids_with_text_changes(work_package_ids, window)
      Journal.for_work_package
             .where(journable_id: work_package_ids, updated_at: window)
             .includes(:data)
             .select { |journal| changes_embedded_text?(journal) }
             .map(&:journable_id)
             .uniq
    end

    # details diffs the journal's snapshot against its predecessor. The initial
    # journal has no predecessor, so new work packages always count as changed.
    def changes_embedded_text?(journal)
      journal.initial? ||
        journal.details.slice(*Llm::WorkPackages::EmbeddableText::EMBEDDED_ATTRIBUTES).present?
    end

    def prerequisites_met?(semantic_index)
      LlmConnection.available? && offers_embedding_model?(semantic_index.model_id)
    end

    def prerequisites_error(_semantic_index)
      LlmConnection.available? ? :model_missing : :no_connection
    end

    def offers_embedding_model?(model_id)
      LlmConnection.active_connection.embedding_model_ids.include?(model_id)
    end

    # Temporary condition (no connection, model no longer offered): recorded as
    # error data, never as a state. Releasing the claim lets the batch's finish
    # callback no-op and lets the admin start again immediately.
    def record_prerequisite_error(semantic_index)
      kind = prerequisites_error(semantic_index)
      message = I18n.t(kind, scope: "admin.semantic_indexes.indexing.not_ready", model: semantic_index.model_id)
      semantic_index.record_error!(kind: kind.to_s, message:)
    end
  end
end
