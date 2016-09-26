# encoding: utf-8
#

require 'spec_helper'

describe Spree::Adjustment, type: :model do
  let!(:store) { create :store }
  let(:order) { Spree::Order.new }
  let(:line_item) { create :line_item, order: order }

  let(:adjustment) { Spree::Adjustment.create!(label: 'Adjustment', adjustable: order, order: order, amount: 5) }

  context '#save' do
    let(:adjustment) { Spree::Adjustment.create(label: "Adjustment", amount: 5, order: order, adjustable: line_item) }

    it 'touches the adjustable' do
      line_item.update_columns(updated_at: 1.day.ago)
      expect { adjustment.save! }.to change { line_item.updated_at }
    end
  end

  describe 'non_tax scope' do
    subject do
      Spree::Adjustment.non_tax.to_a
    end

    let!(:tax_adjustment) do
      create(:adjustment, adjustable: order, order: order, source: create(:tax_rate))
    end

    let!(:non_tax_adjustment_with_source) do
      create(:adjustment, adjustable: order, order: order, source_type: 'Spree::Order', source_id: nil)
    end

    let!(:non_tax_adjustment_without_source) do
      create(:adjustment, adjustable: order, order: order, source: nil)
    end

    it 'select non-tax adjustments' do
      expect(subject).to_not include tax_adjustment
      expect(subject).to     include non_tax_adjustment_with_source
      expect(subject).to     include non_tax_adjustment_without_source
    end
  end

  context '#currency' do
    let(:order) { Spree::Order.new currency: 'JPY' }

    it 'returns the adjustables currency' do
      expect(adjustment.currency).to eq 'JPY'
    end

    context 'adjustable is nil' do
      before do
        adjustment.adjustable = nil
      end
      it 'uses the global currency of USD' do
        expect(adjustment.currency).to eq 'USD'
      end
    end
  end

  context "#display_amount" do
    before { adjustment.amount = 10.55 }

    it "shows the amount" do
      expect(adjustment.display_amount.to_s).to eq "$10.55"
    end

    context "with currency set to JPY" do
      let(:order) { Spree::Order.new currency: 'JPY' }

      context "when adjustable is set to an order" do
        it "displays in JPY" do
          expect(adjustment.display_amount.to_s).to eq "¥11"
        end
      end
    end
  end

  context '#update!' do
    let(:adjustment) { Spree::Adjustment.create!(label: 'Adjustment', order: order, adjustable: order, amount: 5, finalized: finalized, source: source) }
    let(:source) { mock_model(Spree::TaxRate, compute_amount: 10) }

    subject { adjustment.update! }

    context "when adjustment is closed" do
      let(:finalized) { true }

      it "does not update the adjustment" do
        expect(adjustment).to_not receive(:update_column)
        subject
      end
    end

    context "when adjustment isn't finalized" do
      let(:finalized) { false }

      it "updates the amount" do
        expect { subject }.to change { adjustment.amount }.to(10)
      end

      context "it is a promotion adjustment" do
        let(:promotion) { create(:promotion, :with_order_adjustment, starts_at: promo_start_date) }
        let(:promo_start_date) { nil }
        let(:promotion_code) { promotion.codes.first }
        let(:order) { create(:order_with_line_items, line_items_count: 1) }

        let!(:adjustment) do
          promotion.activate(order: order, promotion_code: promotion_code)
          order.adjustments.first
        end

        context "the promotion is eligible" do
          it "sets the adjustment elgiible to true" do
            subject
            expect(adjustment.eligible).to eq true
          end
        end

        context "the promotion is not eligible" do
          let(:promo_start_date) { Date.tomorrow }

          it "sets the adjustment elgiible to false" do
            subject
            expect(adjustment.eligible).to eq false
          end
        end
      end
    end
  end

  describe "promotion code presence error" do
    subject do
      adjustment.valid?
      adjustment.errors[:promotion_code]
    end

    context "when the adjustment is not a promotion adjustment" do
      let(:adjustment) { build(:adjustment) }

      it { is_expected.to be_blank }
    end

    context "when the adjustment is a promotion adjustment" do
      let(:adjustment) { build(:adjustment, source: promotion.actions.first) }
      let(:promotion) { create(:promotion, :with_order_adjustment) }

      context "when the promotion does not have a code" do
        it { is_expected.to be_blank }
      end

      context "when the promotion has a code" do
        let!(:promotion_code) { create(:promotion_code, promotion: promotion) }

        it { is_expected.to include("can't be blank") }
      end
    end
  end

  describe 'repairing adjustment associations' do
    context 'on create' do
      let(:adjustable) { order }
      let(:adjustment_source) { promotion.actions[0] }
      let(:order) { create(:order) }
      let(:promotion) { create(:promotion, :with_line_item_adjustment) }

      def expect_deprecation_warning
        expect(Spree::Deprecation).to(
          receive(:warn).
          with(
            /Adjustment \d+ was not added to #{adjustable.class} #{adjustable.id}/,
            instance_of(Array),
          )
        )
      end

      context 'when adding adjustments via the wrong association' do
        def create_adjustment
          adjustment_source.adjustments.create!(
            amount: 10,
            adjustable: adjustable,
            order: order,
            label: 'some label',
          )
        end

        context 'when adjustable.adjustments is loaded' do
          before { adjustable.adjustments.to_a }

          it 'repairs adjustable.adjustments' do
            expect_deprecation_warning
            adjustment = create_adjustment
            expect(adjustable.adjustments).to include(adjustment)
          end
        end

        context 'when adjustable.adjustments is not loaded' do
          it 'does repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            create_adjustment
          end
        end
      end

      context 'when adding adjustments via the correct association' do
        def create_adjustment
          adjustable.adjustments.create!(
            amount: 10,
            source: adjustment_source,
            order: order,
            label: 'some label',
          )
        end

        context 'when adjustable.adjustments is loaded' do
          before { adjustable.adjustments.to_a }

          it 'does not repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            create_adjustment
          end
        end

        context 'when adjustable.adjustments is not loaded' do
          it 'does not repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            create_adjustment
          end
        end
      end
    end

    context 'on destroy' do
      let(:adjustment) { create(:adjustment) }
      let(:adjustable) { adjustment.adjustable }

      def expect_deprecation_warning(adjustable)
        expect(Spree::Deprecation).to(
          receive(:warn).
          with(
            /Adjustment #{adjustment.id} was not removed from #{adjustable.class} #{adjustable.id}/,
            instance_of(Array),
          )
        )
      end

      context 'when destroying adjustments not via association' do
        context 'when adjustable.adjustments is loaded' do
          before { adjustable.adjustments.to_a }

          it 'repairs adjustable.adjustments' do
            expect_deprecation_warning(adjustable)
            adjustment.destroy!
            expect(adjustable.adjustments).not_to include(adjustment)
          end
        end

        context 'when adjustable.adjustments is not loaded' do
          it 'does repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            adjustment.destroy!
          end
        end
      end

      context 'when destroying adjustments via the association' do
        context 'when adjustable.adjustments is loaded' do
          before { adjustable.adjustments.to_a }

          it 'does not repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            adjustable.adjustments.destroy(adjustment)
          end
        end

        context 'when adjustable.adjustments is not loaded' do
          it 'does not repair' do
            expect(Spree::Deprecation).not_to receive(:warn)
            adjustable.adjustments.destroy(adjustment)
          end
        end
      end
    end
  end
end
