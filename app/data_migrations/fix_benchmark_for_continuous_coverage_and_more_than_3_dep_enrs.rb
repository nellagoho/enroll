# frozen_string_literal: true

require File.join(Rails.root, 'lib/mongoid_migration_task')

# This class is for updating TaxHouseholdEnrollment objects for Health Enrollments that got created on or after 2022/1/1.
#   1. Continuous Coverage
#   2. With more than 3 dependents which have incorrect BenchmarkPremiums
# This class will not update Enrollment.
class FixBenchmarkForContinuousCoverageAndMoreThan3DepEnrs < MongoidMigrationTask
  def update_not_needed?(household_info, th_enrollment)
    th_enrollment.household_benchmark_ehb_premium.to_d == household_info.household_benchmark_ehb_premium.to_d &&
      th_enrollment.health_product_hios_id == household_info.health_product_hios_id &&
      th_enrollment.dental_product_hios_id == household_info.dental_product_hios_id &&
      th_enrollment.household_health_benchmark_ehb_premium.to_d == household_info.household_health_benchmark_ehb_premium.to_d &&
      th_enrollment.household_dental_benchmark_ehb_premium.to_d == household_info.household_dental_benchmark_ehb_premium.to_d
  end

  def update_benchmark_premiums(family, enrollment, enrolled_family_member_ids, old_tax_hh_enrs)
    households_hash = old_tax_hh_enrs.inject([]) do |result, tax_hh_enr|
      members_hash = (tax_hh_enr.tax_household.aptc_members.map(&:applicant_id) & enrolled_family_member_ids).inject([]) do |member_result, member_id|
        family_member = family.family_members.where(id: member_id).first

        member_result << {
          family_member_id: member_id,
          coverage_start_on: enrollment.hbx_enrollment_members.where(applicant_id: member_id).first&.coverage_start_on,
          relationship_with_primary: family_member.primary_relationship
        }

        member_result
      end
      next result if members_hash.blank?

      result << {
        household_id: tax_hh_enr.tax_household_id.to_s,
        members: members_hash
      }
      result
    end

    if households_hash.blank?
      @logger.info "---------- EnrHbxID: #{enrollment.hbx_id} - Unable to construct Benchmark Premiums payload"
      return
    end

    payload = {
      family_id: family.id,
      effective_date: enrollment.effective_on,
      households: households_hash
    }
    benchmark_premiums = ::Operations::BenchmarkProducts::IdentifySlcspWithPediatricDentalCosts.new.call(payload).success
    old_tax_hh_enrs.each do |th_enrollment|
      household_info = benchmark_premiums.households.find { |household| household.household_id.to_s == th_enrollment.tax_household_id.to_s }
      if update_not_needed?(household_info, th_enrollment)
        @logger.info "---------- EnrHbxID: #{enrollment.hbx_id} - Update not needed as TaxHouseholdEnrollment information is same. TaxHousehold hbx_assigned_id: #{th_enrollment.tax_household.hbx_assigned_id}"
        next th_enrollment
      end
      th_enrollment.update!(
        household_benchmark_ehb_premium: household_info.household_benchmark_ehb_premium,
        health_product_hios_id: household_info.health_product_hios_id,
        dental_product_hios_id: household_info.dental_product_hios_id,
        household_health_benchmark_ehb_premium: household_info.household_health_benchmark_ehb_premium,
        household_dental_benchmark_ehb_premium: household_info.household_dental_benchmark_ehb_premium
      )
    end
    true
  end

  def process_enrollment(enrollment)
    old_tax_hh_enrs = TaxHouseholdEnrollment.where(enrollment_id: enrollment.id)
    if old_tax_hh_enrs.blank?
      @logger.info "---------- EnrHbxID: #{enrollment.hbx_id} - No TaxHouseholdEnrollments for Enrollment"
      return
    end

    old_household_benchmark_ehb_premiums = old_tax_hh_enrs.pluck(:household_benchmark_ehb_premium)
    old_health_product_hios_ids = old_tax_hh_enrs.pluck(:health_product_hios_id)
    old_dental_product_hios_ids = old_tax_hh_enrs.pluck(:dental_product_hios_id)
    old_household_health_benchmark_ehb_premiums = old_tax_hh_enrs.pluck(:household_health_benchmark_ehb_premium)
    old_household_dental_benchmark_ehb_premiums = old_tax_hh_enrs.pluck(:household_dental_benchmark_ehb_premium)
    old_applied_aptcs = old_tax_hh_enrs.pluck(:applied_aptc)
    old_available_max_aptcs = old_tax_hh_enrs.pluck(:available_max_aptc)
    enrollment_members_info = enrollment.hbx_enrollment_members.inject({}) do |haash, enr_member|
      haash[enr_member.person.full_name] = enr_member.coverage_start_on.to_s
      haash
    end
    family = enrollment.family
    enrolled_family_member_ids = enrollment.hbx_enrollment_members.map(&:applicant_id)
    updated = update_benchmark_premiums(family, enrollment, enrolled_family_member_ids, old_tax_hh_enrs)
    return unless updated

    new_tax_hh_enrs = TaxHouseholdEnrollment.where(enrollment_id: enrollment.id)
    [
      family.primary_person.hbx_id,
      enrollment.hbx_id,
      enrollment.aasm_state,
      enrollment.total_premium.to_f,
      enrollment.effective_on,
      enrollment.product.ehb,
      enrollment.applied_aptc_amount.to_f,
      enrollment_members_info,
      old_household_benchmark_ehb_premiums,
      old_health_product_hios_ids,
      old_dental_product_hios_ids,
      old_household_health_benchmark_ehb_premiums,
      old_household_dental_benchmark_ehb_premiums,
      old_applied_aptcs,
      old_available_max_aptcs,
      new_tax_hh_enrs.pluck(:household_benchmark_ehb_premium),
      new_tax_hh_enrs.pluck(:health_product_hios_id),
      new_tax_hh_enrs.pluck(:dental_product_hios_id),
      new_tax_hh_enrs.pluck(:household_health_benchmark_ehb_premium),
      new_tax_hh_enrs.pluck(:household_dental_benchmark_ehb_premium),
      new_tax_hh_enrs.pluck(:applied_aptc),
      new_tax_hh_enrs.pluck(:available_max_aptc)
    ]
  end

  def find_enrollment_hbx_ids
    hbx_ids = ENV['enrollment_hbx_ids'].to_s.split(',').map(&:squish!)
    return hbx_ids if hbx_ids.present?

    enr_with_more_than_3_dependent_hbx_ids =
      HbxEnrollment.where(
        :effective_on.gte => Date.new(2022),
        :aasm_state.ne => ['shopping', 'coverage_canceled'],
        :'hbx_enrollment_members.3'.exists => true,
        :product_id.ne => nil,
        coverage_kind: 'health'
      ).pluck(:hbx_id)

    continuous_coverage_enrollment_hbx_ids =
      HbxEnrollment.collection.aggregate(
        [
          {
            "$match" => {
              "hbx_enrollment_members" => {"$ne" => nil},
              "coverage_kind" => "health",
              "consumer_role_id" => {"$ne" => nil},
              "product_id" => {"$ne" => nil},
              "aasm_state" => {"$nin" => ['shopping', 'coverage_canceled']},
              "effective_on" => {"$gte" => Date.new(2022)}
            }
          },
          {
            "$project" => {
              "hbx_enrollment_members" => "$hbx_enrollment_members",
              "effective_on" => "$effective_on",
              "hbx_id" => "$hbx_id"
            }
          },
          {"$unwind" => "$hbx_enrollment_members"},
          {
            "$match" => {
              "$expr" => {
                "$ne" => [
                  { "$dateToString" => { "format" => "%Y-%m-%d", date: "$hbx_enrollment_members.coverage_start_on" }},
                  { "$dateToString": { "format": "%Y-%m-%d", date: "$effective_on" }}
                ]
              }
            }
          },
          "$group" => { "_id" => "$hbx_id"}
        ]
      ).map { |rec| rec['_id'] }

    (enr_with_more_than_3_dependent_hbx_ids + continuous_coverage_enrollment_hbx_ids).uniq
  end

  def process_hbx_enrollment_hbx_ids
    file_name = "#{Rails.root}/benchmark_for_continuous_coverage_enrollments_list_#{TimeKeeper.date_of_record.strftime('%Y_%m_%d')}.csv"
    counter = 0

    field_names = %w[person_hbx_id enrollment_hbx_id enrollment_aasm_state enrollment_total_premium enrollment_effective_on
                     product_ehb enrollment_applied_aptc_amount enrollment_members_with_coverage_start_on
                     old_household_benchmark_ehb_premiums old_health_product_hios_ids old_dental_product_hios_ids old_household_health_benchmark_ehb_premiums
                     old_household_dental_benchmark_ehb_premiums old_applied_aptcs old_available_max_aptcs
                     new_household_benchmark_ehb_premiums new_health_product_hios_ids new_dental_product_hios_ids new_household_health_benchmark_ehb_premiums
                     new_household_dental_benchmark_ehb_premiums new_applied_aptcs new_available_max_aptcs]

    CSV.open(file_name, 'w', force_quotes: true) do |csv|
      csv << field_names
      enr_hbx_ids = find_enrollment_hbx_ids
      enr_hbx_ids.each do |hbx_id|
        counter += 1
        @logger.info "Processed #{counter} hbx_enrollments" if counter % 100 == 0
        @logger.info "----- EnrHbxID: #{hbx_id} - Processing Enrollment"
        enrollment = HbxEnrollment.by_hbx_id(hbx_id).first
        if enrollment.blank?
          @logger.info "---------- EnrHbxID: #{enrollment.hbx_id} - Enrollment not found"
          next hbx_id
        end

        csv_result = process_enrollment(enrollment)
        next hbx_id if csv_result.nil?

        csv << csv_result
        @logger.info "---------- EnrHbxID: #{hbx_id} - Finished processing Enrollment"
      rescue StandardError => e
        @logger.info "---------- EnrHbxID: #{hbx_id} - Error raised processing enrollment, error: #{e}, backtrace: #{e.backtrace}"
      end
    end
  end

  def migrate
    @logger = Logger.new("#{Rails.root}/log/fix_benchmark_for_continuous_coverage_enrollments_#{TimeKeeper.date_of_record.strftime('%Y_%m_%d')}.log")
    start_time = DateTime.current
    @logger.info "FixBenchmarkForContinuousCoverageAndMoreThan3DepEnrs start_time: #{start_time}"
    process_hbx_enrollment_hbx_ids
    end_time = DateTime.current
    @logger.info "FixBenchmarkForContinuousCoverageAndMoreThan3DepEnrs end_time: #{end_time}, total_time_taken_in_minutes: #{((end_time - start_time) * 24 * 60).to_f.ceil}"
  end
end
