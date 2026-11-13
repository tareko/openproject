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
require "spec_helper"
require_module_spec_helper

RSpec.describe SemanticIndex do
  include_context "with an embedding model offered"

  subject(:semantic_index) { build(:semantic_index) }

  def create_batch(index, **properties)
    GoodJob::Batch.new(semantic_index_id: index.id, full_index: true, window_started_at: Time.current, **properties).tap(&:save)
  end

  it "starts out as not indexed" do
    expect(semantic_index.save).to be(true)
    expect(semantic_index.reload.status).to eq("not_indexed")
  end

  it "requires a title" do
    semantic_index.title = ""

    expect(semantic_index).not_to be_valid
    expect(semantic_index.errors.details[:title]).to include(error: :blank)
  end

  %i[embedding_vector_dimensions context_token_length].each do |attribute|
    it "requires a positive integer #{attribute}" do
      semantic_index.public_send(:"#{attribute}=", 0)

      expect(semantic_index).not_to be_valid
      expect(semantic_index.errors.details[attribute]).to include(a_hash_including(error: :greater_than))
    end
  end

  it "rejects embedding vector dimensions above the supported maximum" do
    semantic_index.embedding_vector_dimensions = WorkPackageEmbedding::DIMENSIONS + 1

    expect(semantic_index).not_to be_valid
    expect(semantic_index.errors.details[:embedding_vector_dimensions])
      .to include(a_hash_including(error: :less_than_or_equal_to, value: WorkPackageEmbedding::DIMENSIONS + 1))
  end

  describe "#status" do
    it "is derived from the claimed batch and the watermark, never stored" do
      expect(create(:semantic_index).status).to eq("not_indexed")
      expect(create(:semantic_index, :ready).status).to eq("ready")
      expect(create(:semantic_index, :indexing).status).to eq("indexing")
      expect(create(:semantic_index, :indexing, :ready).status).to eq("indexing")
    end
  end

  describe "#start_indexing!" do
    it "claims the index and clears the previous error" do
      semantic_index = create(:semantic_index, error_kind: "no_connection", error_message: "Some Error")

      batch = semantic_index.start_indexing! { create_batch(semantic_index) }

      expect(batch).to be_present
      expect(semantic_index.reload)
        .to have_attributes(indexing_batch_id: batch.id, error_kind: nil, error_message: nil, failed_work_package_count: 0)
      expect(semantic_index.status).to eq("indexing")
    end

    it "claims a ready index again for a re-index" do
      semantic_index = create(:semantic_index, :ready)

      semantic_index.start_indexing! { create_batch(semantic_index) }

      expect(semantic_index.reload.status).to eq("indexing")
      expect(semantic_index).to be_searchable
    end

    it "refuses to start while a run is in progress" do
      semantic_index = create(:semantic_index, :indexing)

      expect { semantic_index.start_indexing! { create_batch(semantic_index) } }
        .to raise_error(SemanticIndex::InvalidTransitionError)
      expect(semantic_index.reload.status).to eq("indexing")
    end

    it "refuses when the batch could not be created because another run claimed the index" do
      semantic_index = create(:semantic_index)

      expect { semantic_index.start_indexing! { nil } }.to raise_error(SemanticIndex::InvalidTransitionError)
      expect(semantic_index.reload.indexing_batch_id).to be_nil
    end
  end

  describe "#finish_indexing!" do
    let(:semantic_index) { create(:semantic_index, :indexing, last_indexing_started_at: 2.hours.ago) }
    let(:batch) { semantic_index.indexing_batch }

    it "releases the claim, advances the watermark and clears the error" do
      semantic_index.update!(error_kind: "no_connection", error_message: "Some Error")

      semantic_index.finish_indexing!(batch, window_started_at: 1.hour.ago)

      semantic_index.reload
      expect(semantic_index.status).to eq("ready")
      expect(semantic_index.indexing_batch_id).to be_nil
      expect(semantic_index.last_indexing_started_at).to be_within(1.second).of(1.hour.ago)
      expect(semantic_index.error_kind).to be_nil
      expect(semantic_index.error_message).to be_nil
    end

    it "never moves the watermark backwards" do
      semantic_index.finish_indexing!(batch, window_started_at: 3.hours.ago)

      expect(semantic_index.reload.last_indexing_started_at).to be_within(1.second).of(2.hours.ago)
    end

    it "refuses to finish a batch that is not the claimed run" do
      other_batch = create_batch(semantic_index, full_index: false)

      expect { semantic_index.finish_indexing!(other_batch, window_started_at: 1.hour.ago) }
        .to raise_error(SemanticIndex::InvalidTransitionError)
      expect(semantic_index.reload.status).to eq("indexing")
    end
  end

  describe "#record_embedding_failures!" do
    let(:semantic_index) { create(:semantic_index, :indexing, last_indexing_started_at: 2.hours.ago) }
    let(:batch) { semantic_index.indexing_batch }

    it "reports the failed work packages as data and keeps the watermark so the next run retries" do
      semantic_index.record_embedding_failures!(batch, failed_work_package_count: 3)

      semantic_index.reload
      expect(semantic_index.status).to eq("ready")
      expect(semantic_index).to have_attributes(error_kind: "embedding_failures", failed_work_package_count: 3)
      expect(semantic_index.error_message).to eq("3 work packages could not be embedded.")
      expect(semantic_index.last_indexing_started_at).to be_within(1.second).of(2.hours.ago)
      expect(semantic_index.indexing_batch_id).to be_nil
    end

    it "leaves a never-indexed index not indexed but still reports the error" do
      semantic_index = create(:semantic_index, :indexing)

      semantic_index.record_embedding_failures!(semantic_index.indexing_batch, failed_work_package_count: 2)

      semantic_index.reload
      expect(semantic_index.status).to eq("not_indexed")
      expect(semantic_index.error_kind).to eq("embedding_failures")
      expect(semantic_index).not_to be_searchable
    end
  end

  describe "#record_error!" do
    it "records a temporary failure as data from any status; it never gates searching" do
      index = create(:semantic_index, :ready)

      index.record_error!(kind: "no_connection", message: "No active LLM connection is configured.")

      index.reload
      expect(index).to have_attributes(error_kind: "no_connection",
                                       error_message: "No active LLM connection is configured.")
      expect(index.status).to eq("ready")
      expect(index).to be_searchable
    end

    it "releases the claim so the batch's finish callback no-ops and a new run can start" do
      index = create(:semantic_index, :indexing)

      index.record_error!(kind: "model_missing", message: "gone")

      index.reload
      expect(index.indexing_batch_id).to be_nil
      expect(index.status).to eq("not_indexed")
      expect(index).to be_indexable
    end
  end

  describe "#stop_indexing!" do
    it "releases the claim; a previously indexed index stays ready and searchable" do
      semantic_index = create(:semantic_index, :indexing, last_indexing_started_at: 1.hour.ago)

      semantic_index.stop_indexing!

      semantic_index.reload
      expect(semantic_index.indexing_batch_id).to be_nil
      expect(semantic_index.status).to eq("ready")
      expect(semantic_index).to be_searchable
    end

    it "returns a never-indexed index to not indexed" do
      semantic_index = create(:semantic_index, :indexing)

      semantic_index.stop_indexing!

      expect(semantic_index.reload.status).to eq("not_indexed")
    end

    it "refuses when no run is in progress" do
      semantic_index = create(:semantic_index, :ready)

      expect { semantic_index.stop_indexing! }.to raise_error(SemanticIndex::InvalidTransitionError)
      expect(semantic_index.reload.status).to eq("ready")
    end
  end

  describe "#searchable?" do
    it "is true once a run has completed (watermark present), also while re-indexing" do
      expect(create(:semantic_index, :ready)).to be_searchable
      expect(create(:semantic_index, :ready, :indexing)).to be_searchable
    end

    it "is false before the first run completed" do
      expect(create(:semantic_index)).not_to be_searchable
      expect(create(:semantic_index, :indexing)).not_to be_searchable
    end
  end

  describe "#active?" do
    let(:semantic_index) { create(:semantic_index, :ready) }

    it "is active once the semantic search binding references it" do
      expect { connection.feature_bindings.create!(feature_key: "semantic_search", semantic_index:) }
        .to change(semantic_index, :active?).from(false).to(true)
    end

    it "cannot be destroyed while active" do
      connection.feature_bindings.create!(feature_key: "semantic_search", semantic_index:)

      expect(semantic_index.destroy).to be(false)
      expect(described_class.exists?(semantic_index.id)).to be(true)
    end
  end
end
