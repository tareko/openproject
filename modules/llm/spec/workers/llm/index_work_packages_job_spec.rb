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

require "spec_helper"
require_module_spec_helper

RSpec.describe Llm::IndexWorkPackagesJob,
               with_flag: { llm_connection: true, semantic_search: true },
               with_good_job_batches: [Llm::IndexWorkPackagesJob, Llm::EmbedWorkPackagesJob],
               with_settings: { llm_features_enabled: true } do
  let(:semantic_index) { create(:semantic_index, :indexing) }

  describe ".enqueue_for" do
    it "enqueues the job inside a batch that finishes the Semantic Index and carries the window start" do
      batch = described_class.enqueue_for(semantic_index)

      expect(batch.properties).to include(semantic_index_id: semantic_index.id, full_index: true)
      expect(batch.properties[:window_started_at]).to be_within(1.second).of(Time.current)
      expect(batch.on_finish).to eq(Llm::FinishSemanticIndexingJob.name)
      expect(GoodJob::Job.where(batch_id: batch.id).pluck(:job_class)).to eq([described_class.name])
    end
  end

  describe "#perform" do
    include_context "with an embedding model offered"

    let!(:work_packages) { create_list(:work_package, 2) }
    let(:batch) { GoodJob::Batch.new }
    let(:job) { described_class.new }

    before { allow(job).to receive(:batch).and_return(batch) }

    def embed_jobs
      GoodJob::Job.where(batch_id: batch.id, job_class: Llm::EmbedWorkPackagesJob.name)
    end

    it "adds an embedding job for the work packages of the Semantic Index to its batch" do
      job.perform(semantic_index.id)

      expect(embed_jobs.map { it.serialized_params["arguments"] })
        .to contain_exactly([semantic_index.id, match_array(work_packages.map(&:id))])
    end

    it "indexes every work package, ignoring a stored watermark" do
      semantic_index.update!(last_indexing_started_at: 10.minutes.ago)
      old = create(:work_package)
      Journal.for_work_package.where(journable_id: old.id)
             .update_all(created_at: 30.minutes.ago, updated_at: 30.minutes.ago)
      old.update_column(:updated_at, 30.minutes.ago)

      job.perform(semantic_index.id)

      expect(embed_jobs.map { it.serialized_params["arguments"] })
        .to contain_exactly([semantic_index.id, match_array((work_packages + [old]).map(&:id))])
    end

    it "records a temporary error and enqueues nothing without a connection" do
      connection.destroy!

      job.perform(semantic_index.id)

      expect(embed_jobs).to be_empty
      expect(semantic_index.reload)
        .to have_attributes(error_kind: "no_connection",
                            error_message: I18n.t("admin.semantic_indexes.indexing.not_ready.no_connection"),
                            indexing_batch_id: nil)
    end

    it "records a temporary error when the connection no longer offers its model" do
      semantic_index.update!(model_id: "no-longer-offered")

      job.perform(semantic_index.id)

      expect(embed_jobs).to be_empty
      expect(semantic_index.reload)
        .to have_attributes(error_kind: "model_missing",
                            error_message: I18n.t("admin.semantic_indexes.indexing.not_ready.model_missing",
                                                  model: "no-longer-offered"))
    end

    it "does nothing with the feature flag off", with_flag: { semantic_search: false } do
      job.perform(semantic_index.id)

      expect(embed_jobs).to be_empty
      expect(semantic_index.reload.status).to eq("indexing")
    end
  end

  describe "#perform without arguments (incremental sync)" do
    include_context "with an embedding model offered"

    let!(:active_index) do
      create(:semantic_index, :ready, last_indexing_started_at: 10.minutes.ago)
        .tap do |index|
          create(:llm_feature_binding, llm_connection: connection, feature_key: "semantic_search", semantic_index: index)
        end
    end

    before { allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later) }

    # Moves a work package and its journals out of the sync window, so a later
    # save is the only change inside it. Journals aggregate into the previous
    # row, so both timestamps have to move.
    def age_out_of_window(work_package)
      Journal.for_work_package.where(journable_id: work_package.id)
             .update_all(created_at: 30.minutes.ago, updated_at: 30.minutes.ago)
      work_package.update_column(:updated_at, 30.minutes.ago)
      work_package
    end

    def sync_batches
      GoodJob::BatchRecord.where(on_finish: Llm::FinishSemanticIndexingJob.name).order(:created_at, :id)
    end

    # Runs the batch's on_finish callback and marks the batch finished, like
    # GoodJob does when the last job of the batch completes.
    def finish_sync_batch(batch)
      Llm::FinishSemanticIndexingJob.perform_now(batch, { event: :finish })
      batch.update!(finished_at: Time.current)
    end

    it "enqueues the window in a batch that embed jobs join, carrying the window start" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      work_package = create(:work_package)

      described_class.perform_now

      batch = sync_batches.last
      expect(batch.properties[:semantic_index_id]).to eq(active_index.id)
      expect(batch.properties[:full_index]).to be(false)
      expect(batch.properties[:window_started_at]).to be_within(1.second).of(Time.current)
      embed_jobs = GoodJob::Job.where(batch_id: batch.id, job_class: Llm::EmbedWorkPackagesJob.name)
      expect(embed_jobs.map { it.serialized_params["arguments"] })
        .to contain_exactly([active_index.id, [work_package.id]])
    end

    it "claims the index so the cron sync shows as indexing with progress" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      create(:work_package)

      described_class.perform_now

      active_index.reload
      expect(active_index.status).to eq("indexing")
      expect(active_index.indexing_batch_id).to eq(sync_batches.last.id)
      expect(GoodJob::Job.where(batch_id: active_index.indexing_batch_id,
                                job_class: Llm::EmbedWorkPackagesJob.name).count).to eq(1)
    end

    it "embeds work packages whose subject or description changed since the last run and advances the watermark" do
      subject_changed = age_out_of_window(create(:work_package)).tap { |wp| wp.update!(subject: "New subject") }
      description_changed = age_out_of_window(create(:work_package)).tap { |wp| wp.update!(description: "New description") }

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later)
        .with(active_index.id, contain_exactly(subject_changed.id, description_changed.id)).once
      finish_sync_batch(sync_batches.last)
      expect(active_index.reload.last_indexing_started_at).to be_within(1.second).of(Time.current)
    end

    it "embeds newly created work packages" do
      work_package = create(:work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later)
        .with(active_index.id, [work_package.id]).once
    end

    it "skips work packages whose in-window journals do not touch the embedded text" do
      age_out_of_window(create(:work_package)).tap { |wp| wp.update!(estimated_hours: 3) }

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
      finish_sync_batch(sync_batches.last)
      expect(active_index.reload.last_indexing_started_at).to be_within(1.second).of(Time.current)
    end

    it "keeps the watermark when an embed job failed, so the next run re-covers the window" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      work_package = create(:work_package)
      old_watermark = active_index.last_indexing_started_at

      described_class.perform_now
      batch = sync_batches.last
      GoodJob::Job.where(batch_id: batch.id, job_class: Llm::EmbedWorkPackagesJob.name)
                  .update_all(finished_at: Time.current, error: "Llm::Errors::ApiError: boom")
      finish_sync_batch(batch)

      expect(active_index.reload).to have_attributes(error_kind: "embedding_failures",
                                                     failed_work_package_count: 1,
                                                     last_indexing_started_at: old_watermark)

      described_class.perform_now

      new_batch = sync_batches.last
      expect(new_batch.id).not_to eq(batch.id)
      embed_jobs = GoodJob::Job.where(batch_id: new_batch.id, job_class: Llm::EmbedWorkPackagesJob.name)
      expect(embed_jobs.map { it.serialized_params["arguments"] })
        .to contain_exactly([active_index.id, [work_package.id]])
    end

    it "waits while a previous sync batch is still unfinished" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      create(:work_package)

      described_class.perform_now
      described_class.perform_now

      expect(sync_batches.count).to eq(1)
      expect(GoodJob::Job.where(job_class: Llm::EmbedWorkPackagesJob.name).count).to eq(1)
    end

    it "skips the tick while another run holds the claim on the index" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      create(:work_package)
      claimed = GoodJob::BatchRecord.create!(on_finish: Llm::FinishSemanticIndexingJob.name,
                                             serialized_properties: { semantic_index_id: active_index.id,
                                                                      full_index: false })
      active_index.update!(indexing_batch_id: claimed.id)
      expect(active_index.reload.indexing?).to be(true)

      described_class.perform_now

      expect(sync_batches.count).to eq(1)
      expect(GoodJob::Job.where(job_class: Llm::EmbedWorkPackagesJob.name)).to be_empty
    end

    it "skips work packages last touched before the watermark" do
      work_package = create(:work_package)
      work_package.update!(subject: "Old change")
      age_out_of_window(work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
    end

    it "picks up changes in the same second as the watermark" do
      travel_to(Time.current.change(usec: 500_000)) do
        active_index.update_column(:last_indexing_started_at, Time.current)
        work_package = create(:work_package)

        described_class.perform_now

        expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later)
          .with(active_index.id, [work_package.id]).once
      end
    end

    it "embeds every work package when the index has never been indexed" do
      active_index.update_column(:last_indexing_started_at, nil)
      work_packages = create_list(:work_package, 2)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later)
        .with(active_index.id, match_array(work_packages.map(&:id))).once
    end

    it "embeds an index with a recorded error again and clears the error when the run starts" do
      allow(Llm::EmbedWorkPackagesJob).to receive(:perform_later).and_call_original
      active_index.update_columns(error_kind: "no_connection", error_message: "Some Error")
      create(:work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later).once
      expect(active_index.reload).to have_attributes(error_kind: nil, error_message: nil, failed_work_package_count: 0)
      expect(active_index.status).to eq("indexing") # claimed by the cron run
    end

    it "syncs a never-indexed active index" do
      active_index.update_column(:last_indexing_started_at, nil)
      work_package = create(:work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).to have_received(:perform_later)
        .with(active_index.id, [work_package.id]).once
    end

    it "waits while a full index run is in progress" do
      active_index.start_indexing! do
        GoodJob::Batch.new(semantic_index_id: active_index.id, full_index: true,
                           window_started_at: 1.hour.ago).tap(&:save)
      end
      create(:work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
      expect(active_index.reload.last_indexing_started_at).to eq(active_index.last_indexing_started_at_was)
    end

    it "does nothing without an active Semantic Index" do
      active_index.llm_feature_bindings.destroy_all

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
    end

    it "records a temporary error without advancing the watermark when the model is no longer offered" do
      active_index.update!(model_id: "no-longer-offered")
      create(:work_package)

      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
      expect(active_index.reload)
        .to have_attributes(error_kind: "model_missing",
                            error_message: I18n.t("admin.semantic_indexes.indexing.not_ready.model_missing",
                                                  model: "no-longer-offered"))
      expect(active_index.last_indexing_started_at).to eq(active_index.last_indexing_started_at_was)
      expect(active_index.status).to eq("ready") # watermark still present; the error is data, not a state
    end

    it "does nothing with the feature flag off", with_flag: { semantic_search: false } do
      described_class.perform_now

      expect(Llm::EmbedWorkPackagesJob).not_to have_received(:perform_later)
    end
  end
end
