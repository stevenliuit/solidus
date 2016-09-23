module Spree
  class OrderUpdater
    attr_reader :order
    delegate :payments, :line_items, :adjustments, :all_adjustments, :shipments, :update_hooks, :quantity, to: :order

    def initialize(order)
      @order = order
    end

    # This is a multi-purpose method for processing logic related to changes in the Order.
    # It is meant to be called from various observers so that the Order is aware of changes
    # that affect totals and other values stored in the Order.
    #
    # This method should never do anything to the Order that results in a save call on the
    # object with callbacks (otherwise you will end up in an infinite recursion as the
    # associations try to save and then in turn try to call +update!+ again.)
    def update
      update_item_count
      update_totals
      if order.completed?
        update_payment_state
        update_shipments
        update_shipment_state
      end
      run_hooks
      persist_totals
    end

    def run_hooks
      update_hooks.each { |hook| order.send hook }
    end

    # This will update and select the best promotion adjustment, update tax
    # adjustments, update cancellation adjustments, and then update the total
    # fields (promo_total, included_tax_total, additional_tax_total, and
    # adjustment_total) on the item.
    # @return [void]
    def recalculate_adjustments
      # Promotion adjustments must be applied first, then tax adjustments.
      # This fits the criteria for VAT tax as outlined here:
      # http://www.hmrc.gov.uk/vat/managing/charging/discounts-etc.htm#1
      # It also fits the criteria for sales tax as outlined here:
      # http://www.boe.ca.gov/formspubs/pub113/
      update_item_promotions
      update_order_promotions
      update_taxes
      update_cancellations
      update_item_totals
    end

    # Updates the following Order total values:
    #
    # +payment_total+      The total value of all finalized Payments (NOTE: non-finalized Payments are excluded)
    # +item_total+         The total value of all LineItems
    # +adjustment_total+   The total value of all adjustments (promotions, credits, etc.)
    # +promo_total+        The total value of all promotion adjustments
    # +total+              The so-called "order total."  This is equivalent to +item_total+ plus +adjustment_total+.
    def update_totals
      update_payment_total
      update_item_total
      update_shipment_total
      update_adjustment_total
    end

    # give each of the shipments a chance to update themselves
    def update_shipments
      shipments.each do |shipment|
        next unless shipment.persisted?
        shipment.update!(order)
        shipment.refresh_rates
        shipment.update_amounts
      end
    end

    def update_payment_total
      order.payment_total = payments.completed.includes(:refunds).map { |payment| payment.amount - payment.refunds.sum(:amount) }.sum
    end

    def update_shipment_total
      order.shipment_total = shipments.to_a.sum(&:cost)
      update_order_total
    end

    def update_order_total
      order.total = order.item_total + order.shipment_total + order.adjustment_total
    end

    def update_adjustment_total
      recalculate_adjustments

      all_items = line_items + shipments

      order.adjustment_total = all_items.sum(&:adjustment_total) + adjustments.select(&:eligible?).sum(&:amount)
      order.included_tax_total = all_items.sum(&:included_tax_total)
      order.additional_tax_total = all_items.sum(&:additional_tax_total)

      order.promo_total = all_items.sum(&:promo_total) + adjustments.select(&:eligible?).select(&:promotion?).sum(&:amount)

      update_order_total
    end

    def update_item_count
      order.item_count = quantity
    end

    def update_item_total
      order.item_total = line_items.to_a.sum(&:amount)
      update_order_total
    end

    def persist_totals
      order.save!(validate: false)
    end

    # Updates the +shipment_state+ attribute according to the following logic:
    #
    # shipped   when all Shipments are in the "shipped" state
    # partial   when at least one Shipment has a state of "shipped" and there is another Shipment with a state other than "shipped"
    #           or there are InventoryUnits associated with the order that have a state of "sold" but are not associated with a Shipment.
    # ready     when all Shipments are in the "ready" state
    # backorder when there is backordered inventory associated with an order
    # pending   when all Shipments are in the "pending" state
    #
    # The +shipment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
    def update_shipment_state
      if order.backordered?
        order.shipment_state = 'backorder'
      else
        # get all the shipment states for this order
        shipment_states = shipments.states
        if shipment_states.size > 1
          # multiple shiment states means it's most likely partially shipped
          order.shipment_state = 'partial'
        else
          # will return nil if no shipments are found
          order.shipment_state = shipment_states.first
          # TODO: inventory unit states?
          # if order.shipment_state && order.inventory_units.where(:shipment_id => nil).exists?
          #   shipments exist but there are unassigned inventory units
          #   order.shipment_state = 'partial'
          # end
        end
      end

      order.state_changed('shipment')
      order.shipment_state
    end

    # Updates the +payment_state+ attribute according to the following logic:
    #
    # paid          when +payment_total+ is equal to +total+
    # balance_due   when +payment_total+ is less than +total+
    # credit_owed   when +payment_total+ is greater than +total+
    # failed        when most recent payment is in the failed state
    #
    # The +payment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
    def update_payment_state
      last_state = order.payment_state
      if payments.present? && payments.valid.size == 0 && order.outstanding_balance != 0
        order.payment_state = 'failed'
      elsif order.state == 'canceled' && order.payment_total == 0
        order.payment_state = 'void'
      else
        order.payment_state = 'balance_due' if order.outstanding_balance > 0
        order.payment_state = 'credit_owed' if order.outstanding_balance < 0
        order.payment_state = 'paid' if !order.outstanding_balance?
      end
      order.state_changed('payment') if last_state != order.payment_state
      order.payment_state
    end

    private

    def round_money(n)
      (n * 100).round / 100.0
    end

    def update_item_promotions
      [*line_items, *shipments].each do |item|
        promotion_adjustments = item.adjustments.select(&:promotion?)

        promotion_adjustments.each(&:update!)
        Spree::Config.promotion_chooser_class.new(promotion_adjustments).update

        item.promo_total = promotion_adjustments.select(&:eligible?).sum(&:amount)
      end
    end

    # Update and select the best promotion adjustment for the order.
    # We don't update the order.promo_total yet. Order totals are updated later
    # in #update_adjustment_total since they include the totals from the ordre's
    # line items and/or shipments.
    def update_order_promotions
      promotion_adjustments = order.adjustments.select(&:promotion?)
      promotion_adjustments.each(&:update!)
      Spree::Config.promotion_chooser_class.new(promotion_adjustments).update
    end

    def update_taxes
      Spree::Tax::OrderAdjuster.new(order).adjust!

      [*line_items, *shipments].each do |item|
        tax_adjustments = item.adjustments.select(&:tax?)
        # Tax adjustments come in not one but *two* exciting flavours:
        # Included & additional

        # Included tax adjustments are those which are included in the price.
        # These ones should not affect the eventual total price.
        #
        # Additional tax adjustments are the opposite, affecting the final total.
        item.included_tax_total   = tax_adjustments.select(&:included?).sum(&:amount)
        item.additional_tax_total = tax_adjustments.reject(&:included?).sum(&:amount)
      end
    end

    def update_cancellations
      line_items.each do |line_item|
        line_item.adjustments.select(&:cancellation?).each(&:update!)
      end
    end

    def update_item_totals
      [*line_items, *shipments].each do |item|
        # The cancellation_total isn't persisted anywhere but is included in
        # the adjustment_total
        item_cancellation_total = item.adjustments.select(&:cancellation?).sum(&:amount)

        item.adjustment_total = item.promo_total +
                                item.additional_tax_total +
                                item_cancellation_total

        if item.changed?
          item.update_columns(
            promo_total:          item.promo_total,
            included_tax_total:   item.included_tax_total,
            additional_tax_total: item.additional_tax_total,
            adjustment_total:     item.adjustment_total,
            updated_at:           Time.current,
          )
        end
      end
    end
  end
end
